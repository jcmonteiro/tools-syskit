module Syskit
    module Actions
        # A representation of a set of dependency injections and definition of
        # pre-instanciated models
        class Profile
            class << self
                # Set of known profiles
                attr_reader :profiles
            end
            @profiles = Array.new

            dsl_attribute :doc

            class ProfileInstanceRequirements < InstanceRequirements
                attr_accessor :profile
                attr_predicate :advanced?, true
                def initialize(profile, name, advanced: false)
                    super()
                    self.profile = profile
                    self.advanced = advanced
                    self.name = name
                end

                def to_action_model(profile = self.profile, doc = self.doc)
                    action_model = super(profile, doc)
                    action_model.advanced = advanced?
                    action_model
                end
            end

            class Definition < ProfileInstanceRequirements
                def to_action_model(profile = self.profile, doc = self.doc)
                    action_model = resolve.
                        to_action_model(profile, doc || "defined in #{profile}")
                    action_model.advanced = advanced?
                    action_model
                end

                def resolve
                    result = ProfileInstanceRequirements.new(profile, name, advanced: advanced?)
                    result.merge(self)
                    result.name = name
                    profile.inject_di_context(result)
                    result.doc(doc)
                    result
                end
            end

            Tag = Syskit::Models::Placeholder.new_specialized_placeholder do
                # The name of this tag
                attr_accessor :tag_name
                # The profile this tag has been defined on
                attr_accessor :profile
            end

            # Whether this profile should be kept across app setup/cleanup
            # cycles and during model reloading
            attr_predicate :permanent_model?, true

            # Defined here to make profiles look like models w.r.t. Roby's
            # clear_model implementation
            #
            # It does nothing
            def each_submodel
            end

            # The call trace at the time of the profile definition
            attr_reader :definition_location
            # The profile name
            # @return [String]
            attr_reader :name
            # The profile's basename
            def basename; name.gsub(/.*::/, '') end
            # The profile's namespace
            def spacename; name.gsub(/::[^:]*$/, '') end
            # The definitions
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :definitions
            # The tags
            # @return [Hash<String,InstanceRequirements>]
            attr_reader :tags
            # The set of profiles that have been used in this profile with
            # {#use_profile}
            # @return [Array<Profile>]
            attr_reader :used_profiles
            # The DependencyInjection object that is being defined in this
            # profile
            # @return [DependencyInjection]
            attr_reader :dependency_injection
            # The deployments available on this profile
            #
            # @return [Models::DeploymentGroup]
            attr_reader :deployment_group
            # A set of deployment groups that can be used to narrow deployments
            # on tasks
            attr_reader :deployment_groups

            # Dependency injection object that signifies "select nothing for
            # this"
            #
            # This is used to override more generic selections, or to make sure
            # that a compositions' optional child is not present
            #
            # @example disable the optional 'pose' child of Camera composition
            #   Compositions::Camera.use('pose' => nothing)
            #
            def nothing
                DependencyInjection.nothing
            end

            # Robot definition class inside a profile
            #
            # It is subclassed so that we can invalidate the cached dependency
            # injection object whenever the robot gets modified
            class RobotDefinition < Syskit::Robot::RobotDefinition
                # @return [Profile] the profile object this robot definition is
                #   part of
                attr_reader :profile

                def initialize(profile)
                    @profile = profile
                    super()
                end

                def invalidate_dependency_injection
                    super
                    profile.invalidate_dependency_injection
                end

                def to_s
                    "#{profile.name}.robot"
                end
            end
            
            def initialize(name = nil)
                @name = name
                @permanent_model = false
                @definitions = Hash.new
                @tags = Hash.new
                @used_profiles = Array.new
                @dependency_injection = DependencyInjection.new
                @robot = RobotDefinition.new(self)
                @definition_location = call_stack
                @deployment_group = Syskit::Models::DeploymentGroup.new
                @deployment_groups = Hash.new
                super()
            end

            def tag(name, *models)
                tags[name] = Tag.create_for(
                    models,
                    as: "#{self}.#{name}_tag")
                tags[name].tag_name = name
                tags[name].profile = self
                tags[name]
            end

            # Add some dependency injections for the definitions in this profile
            def use(*args)
                invalidate_dependency_injection
                dependency_injection.add(*args)
                self
            end

            def invalidate_dependency_injection
                @di = nil
            end

            def resolved_dependency_injection
                if !@di
                    di = DependencyInjectionContext.new
                    di.push(robot.to_dependency_injection)
                    all_used_profiles.each do |prof, _|
                        di.push(prof.dependency_injection)
                    end
                    di.push(dependency_injection)
                    @di = di.current_state
                end
                @di
            end

            def to_s
                name
            end

            # Promote requirements taken from another profile to this profile
            #
            # @param [Profile] profile the profile the requirements are
            #   originating from
            # @param [InstanceRequirements] req the instance requirement object
            # @param [{String=>Object}] tags selections for tags in profile,
            #   from the tag name to the selected object
            # @return [InstanceRequirements] the promoted requirement object. It
            #   might be the same than the req parameter (i.e. it is not
            #   guaranteed to be a copy)
            def promote_requirements(profile, req, tags = Hash.new)
                if req.composition_model?
                    tags = resolve_tag_selection(profile, tags)
                    req = req.dup
                    req.push_selections
                    req.use(tags)
                end
                req
            end

            # Resolves the names in the tags argument given to {#use_profile}
            def resolve_tag_selection(profile, tags)
                tags.map_key do |key, _|
                    if key.respond_to?(:to_str)
                        profile.send("#{key.gsub(/_tag$/, '')}_tag")
                    else key
                    end
                end
            end

            # Enumerate the profiles that have directly been imported in self
            #
            # @yieldparam [Profile] profile
            def each_used_profile(&block)
                return enum_for(__method__) if !block_given?
                used_profiles.each do |profile, tags|
                    yield(profile)
                end
            end

            # Adds the given profile DI information and registered definitions
            # to this one.
            #
            # If a definitions has the same name in self than in the given
            # profile, the local definition takes precedence
            #
            # @param [Profile] profile
            # @return [void]
            def use_profile(profile, tags = Hash.new)
                invalidate_dependency_injection
                tags = resolve_tag_selection(profile, tags)
                used_profiles.push([profile, tags])
                deployment_group.use_group(profile.deployment_group)

                # Register the definitions, but let the user override
                # definitions of the given profile locally
                profile.definitions.each do |name, req|
                    if !definitions[name]
                        req = promote_requirements(profile, req, tags)
                        new_def = define name, req
                        new_def.doc(req.doc)
                    end
                end
                robot.use_robot(profile.robot)
                super if defined? super
                nil
            end

            # Give a name to a known instance requirement object
            #
            # @return [InstanceRequirements] the added instance requirement
            def define(name, requirements)
                resolved = resolved_dependency_injection.
                    direct_selection_for(requirements) || requirements
                req = resolved.to_instance_requirements
                
                definition = Definition.new(self, "#{name}_def")
                definition.doc MetaRuby::DSLs.parse_documentation_block(->(file) { Roby.app.app_file?(file) }, /^define$/)
                definition.advanced = false
                definition.merge(req)
                definitions[name] = definition
            end

            # Returns the instance requirement object that represents the given
            # definition in the context of this profile
            #
            # @param [String] name the definition name
            # @return [InstanceRequirements] the instance requirement
            #   representing the definition
            # @raise [ArgumentError] if the definition does not exist
            # @see resolved_definition
            def definition(name)
                req = definitions[name]
                if !req
                    raise ArgumentError, "profile #{self.name} has no definition called #{name}"
                end
                req.dup
            end

            # Tests whether self has a definition with a given name
            def has_definition?(name)
                definitions.has_key?(name)
            end

            # Returns the instance requirement object that represents the given
            # definition, with all the dependency injection information
            # contained in this profile applied
            #
            # @param [String] name the definition name
            # @return [InstanceRequirements] the instance requirement
            #   representing the definition
            # @raise [ArgumentError] if the definition does not exist
            # @see definition
            def resolved_definition(name)
                req = definitions[name]
                if !req
                    raise ArgumentError, "profile #{self.name} has no definition called #{name}"
                end
                req.resolve
            end

            # Enumerate all definitions available on this profile
            #
            # @yieldparam [Definition] definition the definition object as given
            #   to {#define}
            #
            # @see each_resolved_definition
            def each_definition(&block)
                return enum_for(__method__) if !block_given?
                definitions.each_value do |req|
                    yield(req.dup)
                end
            end

            # Enumerate all definitions on this profile and resolve them
            #
            # @yieldparam [Definition] definition the definition resolved with
            #   {#resolved_definition}
            def each_resolved_definition
                return enum_for(__method__) if !block_given?
                definitions.each_value do |req|
                    yield(req.resolve)
                end
            end

            # (see Models::DeploymentGroup#find_deployed_task_by_name)
            def find_deployed_task_by_name(task_name)
                deployment_group.find_deployed_task_by_name(task_name)
            end

            # (see Models::DeploymentGroup#use_group)
            def use_group(deployment_group)
                deployment_group.use_group(deployment_group)
            end

            # (see Models::DeploymentGroup#use_ruby_tasks)
            def use_ruby_tasks(mappings, on: 'ruby_tasks')
                deployment_group.use_ruby_tasks(mappings, on: on)
            end

            # (see Models::DeploymentGroup#use_unmanaged_task)
            def use_ruby_tasks(mappings, on: 'ruby_tasks')
                deployment_group.use_unmanaged_task(mappings, on: on)
            end

            # (see Models::DeploymentGroup#use_deployment)
            def use_deployment(*names, on: 'localhost', loader: deployment_group.loader, **run_options)
                deployment_group.use_deployment(*names, on: on, loader: loader, **run_options)
            end

            # (see Models::DeploymentGroup#use_deployments_from)
            def use_deployments_from(project_name, loader: deployment_group.loader, **use_options)
                deployment_group.use_deployments_from(project_name, loader: loader, **use_options)
            end

            # Create a deployment group to specify definition deployments
            #
            # This only defines the group, but does not declare that the profile
            # should use it. To use a group in a profile, do the following:
            #
            # @example
            #   create_deployment_group 'left_arm' do
            #       use_deployments_from 'left_arm'
            #   end
            #   use_group left_arm_deployment_group
            #
            def define_deployment_group(name, &block)
                group = Syskit::Models::DeploymentGroup.new
                group.instance_eval(&block)
                deployment_groups[name] = group
            end

            # Returns a deployment group defined with {#create_deployment_group}
            def find_deployment_group_by_name(name)
                deployment_groups[name]
            end

            # Returns a device from the profile's robot definition
            def find_device_requirements_by_name(device_name)
                robot.devices[device_name].to_instance_requirements.dup
            end

            # Returns the tag object for a given name
            def find_tag_by_name(name)
                tags[name]
            end

            # Returns the definition for a given name
            def find_definition_by_name(name)
                definitions[name]
            end

            # Returns all profiles that are used by self
            def all_used_profiles
                resolve_used_profiles(Array.new, Set.new)
            end

            # @api private
            #
            # Recursively lists all profiles that are used by self
            def resolve_used_profiles(list, set)
                new_profiles = used_profiles.find_all do |p, _|
                    !set.include?(p)
                end
                list.concat(new_profiles)
                set |= new_profiles.map(&:first).to_set
                new_profiles.each do |p, _|
                    p.resolve_used_profiles(list, set)
                end
                list
            end

            # Injects the DI information registered in this profile in the given
            # instance requirements
            #
            # @param [InstanceRequirements] req the instance requirement object
            # @return [void]
            def inject_di_context(req)
                req.deployment_group.use_group(deployment_group)
                req.push_dependency_injection(resolved_dependency_injection)
                super if defined? super
                nil
            end

            def initialize_copy(old)
                super
                old.definitions.each do |name, req|
                    definitions[name] = req.dup
                end
            end

            # @overload robot
            # @overload robot { ... }
            #
            # Gets and/or modifies the robot definition of this profile
            #
            # @return [Syskit::Robot::RobotDefinition] the robot definition
            #   object
            def robot(&block)
                if block_given?
                    @robot.instance_eval(&block)
                end
                @robot
            end

            # Clears this profile of all data, leaving it blank
            #
            # This is mostly used in Roby's model-reloading procedures
            def clear_model
                @robot = Robot::RobotDefinition.new
                definitions.clear
                @dependency_injection = DependencyInjection.new
                @deployment_groups = Hash.new
                @deployment_group = Syskit::Models::DeploymentGroup.new
                used_profiles.clear
                super if defined? super

                if MetaRuby::Registration.accessible_by_name?(self)
                    MetaRuby::Registration.deregister_constant(self)
                end

                Profile.profiles.delete(self)
            end

            # Defined here to make profiles look like models w.r.t. Roby's
            # clear_model implementation
            #
            # It enumerates the profiles created so far
            def self.each_submodel(&block)
                profiles.each(&block)
            end

            def self.clear_model
            end

            def each_action
                return enum_for(__method__) if !block_given?

                robot.each_master_device do |dev|
                    action_model = dev.to_action_model(self)
                    yield(action_model)
                end

                definitions.each do |name, req|
                    action_name = "#{name}_def"
                    action_model = req.to_action_model(self)
                    action_model.name = action_name
                    yield(action_model)
                end
            end

            def method_missing(m, *args)
                MetaRuby::DSLs.find_through_method_missing(
                    self, m, args,
                    'tag' => :find_tag_by_name,
                    'def' => :find_definition_by_name,
                    'dev' => :find_device_requirements_by_name,
                    'task' => :find_deployed_task_by_name,
                    'deployment_group' => :find_deployment_group_by_name) || super
            end

            include Roby::DRoby::V5::DRobyConstant::Dump
        end

        module ProfileDefinitionDSL
            # Declares a new syskit profile, and registers it as a constant on
            # this module
            #
            # A syskit profile is a group of dependency injections (use flags)
            # and instance definitions. All the definitions it contains can
            # then be exported on an action interface using
            # {Profile#use_profile}
            #
            # @return [Syskit::Actions::Profile]
            def profile(name, &block)
                if const_defined_here?(name)
                    profile = const_get(name)
                else 
                    profile = Profile.new("#{self.name}::#{name}")
                    const_set(name, profile)
                    Profile.profiles << profile
                    profile.doc MetaRuby::DSLs.parse_documentation_block(/.*/, "profile")
                end
                profile.instance_eval(&block)
            end
        end
        Module.include ProfileDefinitionDSL
    end
end


