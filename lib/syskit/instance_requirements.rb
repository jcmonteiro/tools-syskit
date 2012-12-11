module Syskit
        # Generic representation of a configured component instance
        class InstanceRequirements
            extend Logger::Hierarchy
            include Logger::Hierarchy

            # The component model narrowed down from +base_models+ using
            # +using_spec+
            attr_reader :models
            # The component model specified by #add
            attr_reader :base_models
            # Required arguments on the final task
            attr_reader :arguments
            # The model selection that can be used to instanciate this task, as
            # a DependencyInjection object
            attr_reader :selections
            # If set, this requirements points to a specific service, not a
            # specific task. Use #select_service to select.
            attr_reader :service

            # The model selection that can be used to instanciate this task,
            # as resolved using names and application of default selections
            #
            # This information is only valid in the instanciation context, i.e.
            # while the underlying engine is instanciating the requirements
            attr_reader :resolved_using_spec

            # A set of hints for deployment disambiguation (as matchers on the
            # deployment names). New hints can be added with #use_deployments
            attr_reader :deployment_hints

            def initialize(models = [])
                @models    = @base_models = models.to_value_set
                @arguments = Hash.new
                @selections = DependencyInjection.new
                @deployment_hints = Set.new
            end

            def initialize_copy(old)
                @models = old.models.dup
                @base_models = old.base_models.dup
                @arguments = old.arguments.dup
                @selections = old.selections.dup
                @deployment_hints = old.deployment_hints.dup
                @service = service
            end

            def self.from_object(object)
                if object.kind_of?(InstanceRequirements)
                    object.dup
                elsif (object.kind_of?(Class) && object <= Component) || object.kind_of?(Models::DataServiceModel)
                    InstanceRequirements.new([object])
                elsif object.kind_of?(Models::BoundDataService)
                    req = InstanceRequirements.new([object.component_model])
                    req.select_service(object)
                    req
                else
                    raise ArgumentError, "expected an instance requirement object, a component model, a data service model or a bound data service, got #{object}"
                end
            end

            # Add new models to the set of required ones
            def add_models(new_models)
                new_models = new_models.dup
                new_models.delete_if { |m| @base_models.any? { |bm| bm.fullfills?(m) } }
                base_models.delete_if { |bm| new_models.any? { |m| m.fullfills?(bm) } }
                @base_models |= new_models.to_value_set
                narrow_model
            end

            # Explicitely selects a given service on the task models required by
            # this task
            #
            # @param [Models::BoundDataService] the data service that should be
            #   selected
            # @raise [ArgumentError] if the provided service is not a service on
            #   a model in self (i.e. not a service of a component model in
            #   {#base_models}
            # @return [Models::BoundDataService] the selected service. If
            #   'service' is a service of a supermodel of a model in {#model},
            #   the resulting BoundDataService is attached to the actual model
            #   in {#model} and this return value is different from 'service'
            def select_service(service)
                # Make sure that the service is bound to one of our models
                component_model = models.find { |m| m.fullfills?(service.component_model) }
                if !component_model
                    raise ArgumentError, "#{service} is not a service of #{self}"
                end
                @service = service.attach(component_model)
            end

            # Finds a data service by name
            #
            # This only works if there is a single component model in {#models}.
            #
            # @param [String] service_name the service name
            # @return [InstanceRequirements,nil] the requirements with the requested
            #   data service selected or nil if there are no service with the
            #   requested name
            # @raise [ArgumentError] if there are no component models in
            #   {#models}
            def find_data_service(service_name)
                task_model = models.find { |m| m <= Syskit::Component }
                if !task_model
                    raise ArgumentError, "cannot select a service on #{models.map(&:short_name).sort.join(", ")} as there are no component models"
                end
                if service = task_model.find_data_service(service_name)
                    result = dup
                    result.select_service(service)
                    result
                end
            end

            # Finds the only data service that matches the given service type
            #
            # @param [Model<DataService>] the data service type
            # @return [InstanceRequirements,nil] this instance requirement object
            #   with the relevant service selected; nil if there are no matches
            # @raise [AmbiguousServiceSelection] if more than one service
            #   matches
            def find_data_service_from_type(service_type)
                candidates = models.find_all do |m|
                    m.fullfills?(service_type)
                end
                if candidates.size > 1
                    raise AmbiguousServiceSelection.new(self, service_type, candidates)
                elsif candidates.empty?
                    return
                end

                model = candidates.first
                if model.respond_to?(:find_data_service_from_type)
                    result = dup
                    result.select_service(model.find_data_service_from_type(service_type))
                    result
                else self
                end
            end

            # Finds the composition's child by name
            #
            # @raise [ArgumentError] if this InstanceRequirements object does
            #   not refer to a composition
            def find_child(name)
                composition = models.find { |m| m <= Composition }
                if !composition
                    raise ArgumentError, "this requirement object does not refer to a composition explicitely, cannot select a child"
                end
                if child = composition.find_child(name)
                    child.attach(self)
                end
            end

            def find_port(name)
                candidates = []
                if service
                    candidates << service.find_port(name)
                end

                models.each do |m|
                    if !service || service.component_model != m
                        candidates << m.find_port(name)
                    end
                end
                if candidates.size > 1
                    raise AmbiguousPortName.new(self, name, candidates)
                end
                if port = candidates.first
                    port.attach(self)
                end
            end

            # Return true if this child provides all of the required models
            def fullfills?(required_models)
                if !required_models.respond_to?(:each)
                    required_models = [required_models]
                end
                if service
                    required_models.all? do |req_m|
                        service.fullfills?(req_m)
                    end
                else
                    required_models.all? do |req_m|
                        models.any? { |m| m.fullfills?(req_m) }
                    end
                end
            end

            # Merges +self+ and +other_spec+ into +self+
            #
            # Throws ArgumentError if the two specifications are not compatible
            # (i.e. can't be merged)
            def merge(other_spec)
                @base_models = Models.merge_model_lists(@base_models, other_spec.base_models)
                @arguments = @arguments.merge(other_spec.arguments) do |name, v1, v2|
                    if v1 != v2
                        raise ArgumentError, "cannot merge #{self} and #{other_spec}: argument value mismatch for #{name}, resp. #{v1} and #{v2}"
                    end
                    v1
                end
                @selections.merge(other_spec.selections)
                if service && other_spec.service && service != other_spec.service
                    @service = nil
                else
                    @service = other_spec.service
                end

                @deployment_hints |= other_spec.deployment_hints
                # Call modules that could have been included in the class to
                # extend it
                super if defined? super

                narrow_model
            end

            def hash; base_models.hash end
            def eql?(obj)
                obj.kind_of?(InstanceRequirements) &&
                    obj.selections == selections &&
                    obj.arguments == arguments &&
		    obj.service == service
            end
            def ==(obj)
                eql?(obj)
            end

            ##
            # :call-seq:
            #   use 'child_name' => 'component_model_or_device'
            #   use 'child_name' => ComponentModel
            #   use ChildModel => 'component_model_or_device'
            #   use ChildModel => ComponentModel
            #   use Model1, Model2, Model3
            #
            # Provides explicit selections for the children of compositions
            #
            # In the first two forms, provides an explicit selection for a
            # given child. The selection can be given either by name (name
            # of the model and/or of the selected device), or by directly
            # giving the model object.
            #
            # In the second two forms, provides an explicit selection for
            # any children that provide the given model. For instance,
            #
            #   use IMU => XsensImu::Task
            #
            # will select XsensImu::Task for any child that provides IMU
            #
            # Finally, the third form allows to specify preferences without
            # being specific about where to put them. If ambiguities are
            # found, and if only one of the possibility is listed there,
            # then that possibility will be selected. It has a lower
            # priority than the explicit selection.
            #
            # See also Composition#instanciate
            def use(*mappings)
                debug "adding use mappings #{mappings} to #{self}"

                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    raise ArgumentError, "#use is available only for compositions, got #{base_models.map(&:short_name).join(", ")}"
                end

                mappings.delete_if do |sel|
                    if sel.kind_of?(DependencyInjection)
                        selections.merge(sel)
                        true
                    end
                end

                explicit, defaults = DependencyInjection.partition_use_arguments(*mappings)
                selections.add_explicit(explicit)
                selections.add_defaults(defaults)
                composition_model = narrow_model || composition_model

                selections.each_selection_key do |obj|
                    if obj.respond_to?(:to_str)
                        # Two choices: either a child of the composition model,
                        # or a child of a child that is a composition itself
                        parts = obj.split('.')
                        first_part = parts.first
                        if !composition_model.has_child?(first_part)
                            raise "#{first_part} is not a known child of #{composition_model.name}"
                        end
                    end
                end

                self
            end

            # Specifies new arguments that must be set to the instanciated task
            def with_arguments(arguments)
                @arguments.merge!(arguments)
                self
            end

            # @deprecated
            def use_conf(*conf)
                Roby.warn_deprecated "InstanceRequirements#use_conf is deprecated. Use #with_conf instead"
                with_conf(*conf)
            end

            # Specifies that the task that is represented by this requirement
            # should use the given configuration
            def with_conf(*conf)
                @arguments[:conf] = conf
                self
            end

            # Use the specified hints to select deployments
            def use_deployments(*patterns)
                @deployment_hints |= patterns.to_set
            end

            # Computes the value of +model+ based on the current selection
            # (in #selections) and the base model specified in #add or
            # #define
            def narrow_model
                composition_model = base_models.find { |m| m <= Composition }
                if !composition_model
                    @models = @base_models
                    return
                elsif composition_model.specializations.empty?
                    @models = @base_models
                    return
                end

                debug do
                    debug "narrowing model"
                    debug "  from #{composition_model.short_name}"
                    break
                end

                context = log_nest(4) do
                    selection = self.selections.dup
                    selection.remove_unresolved
                    DependencyInjectionContext.new(selection)
                end

                result = log_nest(2) do
                    composition_model.narrow(context)
                end

                debug do
                    if result
                        debug "  using #{result.short_name}"
                    end
                    break
                end

                models = base_models.dup
                models.delete_if { |m| result.fullfills?(m) }
                models << result
                @models = models
                return result
            end

            attr_reader :required_host

            # Requires that this spec runs on the given process server, i.e.
            # that all the corresponding tasks are running on that process
            # server
            def on_server(name)
                @required_host = name
            end

            # Returns a task that can be used in the plan as a placeholder for
            # this instance
            def create_proxy_task
                task_model = Syskit.proxy_task_model_for(models)
                task = task_model.new(@arguments)
                task.required_host = self.required_host
                task.abstract = true
                task
            end

            # Create a concrete task for this requirement
            def instanciate(engine, context, arguments = Hash.new)
                task_model =
                    if models.size == 1 && (models.first <= Component)
                        models.first
                    else Syskit.proxy_task_model_for(models)
                    end

                # Add a barrier for the names that our models expect. This is
                # required to avoid recursively reusing names (which was once
                # upon a time, and is a very confusing feature)
                barrier = Hash.new
                models.each do |m|
                    m.dependency_injection_names.each do |n|
                        barrier[n] = nil
                    end
                end
                selections = self.selections
                if !barrier.empty?
                    selections = selections.dup
                    selections.add_explicit(barrier)
                end
                context.push(selections)

                arguments = Kernel.validate_options arguments, :task_arguments => nil
                instanciate_arguments = { :task_arguments => self.arguments }
                if arguments[:task_arguments]
                    instanciate_arguments[:task_arguments].merge!(arguments[:task_arguments])
                end

                task = task_model.instanciate(engine, context, instanciate_arguments)
                task.requirements.merge(self)
                if !task_model.fullfills?(base_models)
                    raise InternalError, "instanciated task #{task} does not provide the required models #{base_models.map(&:short_name).join(", ")}"
                end

                if required_host && task.respond_to?(:required_host=)
                    task.required_host = required_host
                end

                if service
                    service.bind(task)
                else
                    task
                end

            rescue InstanciationError => e
                e.instanciation_chain << self
                raise
            end

            def each_fullfilled_model(&block)
                if service
                    service.each_fullfilled_model(&block)
                else
                    models.each do |m|
                        m.each_fullfilled_model(&block)
                    end
                end
            end

            def fullfilled_model
                task_model = Component
                tags = []
                each_fullfilled_model do |m|
                    if m.kind_of?(Roby::Task)
                        task_model = m
                    else
                        tags << m
                    end
                end
                [task_model, tags, @arguments.dup]
            end

            def as_plan
                Syskit::SingleRequirementTask.subplan(self)
            end

            def to_s
                if base_models.empty?
                    result = "#<#{self.class}: <no models>"
                else
                    result = "#<#{self.class}: models=#{models.map(&:short_name).join(",")} base=#{base_models.map(&:short_name).join(",")}"
                end
                if !selections.empty?
                    result << " using(#{selections})"
                end
                if !arguments.empty?
                    result << " args(#{arguments})"
                end
                if service
                    result << " srv=#{service}"
                end
                result << ">"
            end

            def pretty_print(pp)
                if base_models.empty?
                    pp.text "No models"
                else
                    pp.text "Base Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(base_models, ",") do |mod|
                            pp.text mod.short_name
                        end
                    end

                    pp.breakable
                    pp.text "Narrowed Models:"
                    pp.nest(2) do
                        pp.breakable
                        pp.seplist(models) do |mod|
                            pp.text mod.short_name
                        end
                    end
                end

		if service
		    pp.breakable
		    pp.text "Service:"
		    pp.nest(2) do
			pp.breakable
			service.pretty_print(pp)
		    end
		end

                if !selections.empty?
                    pp.breakable
                    pp.text "Using:"
                    pp.nest(2) do
                        pp.breakable
                        selections.pretty_print(pp)
                    end
                end

                if !arguments.empty?
                    pp.breakable
                    pp.text "Arguments: #{arguments}"
                end
            end

            def method_missing(method, *args)
                if !args.empty? || block_given?
                    return super
                end

		case method.to_s
                when /^(\w+)_srv$/
                    service_name = $1
                    if srv = find_data_service(service_name)
                        return srv
                    end
                    model =
                        if service then service
                        else models.find { |m| m <= Component }.short_name
                        end

                    raise NoMethodError, "#{model.short_name} has no data service called #{service_name}"
                when /^(\w+)_child$/
                    child_name = $1
                    if child = find_child(child_name)
                        return child
                    end
                    raise NoMethodError, "#{models.find { |m| m <= Composition }.short_name} has no child called #{child_name}"
                when /^(\w+)_port$/
                    port_name = $1
                    if port = find_port(port_name)
                        return port
                    end
                    raise NoMethodError, "no port called #{port_name} in any of #{models.map(&:short_name).short.join(", ")}"
                end
                super(method.to_sym, *args)
            end
        end

end
