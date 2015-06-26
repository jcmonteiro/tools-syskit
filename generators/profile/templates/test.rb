require '<%= Roby::App.resolve_robot_in_path("models/#{subdir}/#{basename}") %>'
<% indent, open, close = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>    # Verifies that the only variation points in the profile are
<%= indent %>    # profile tags. If you want to limit the test to certain definitions,
<%= indent %>    # give them as argument
<%= indent %>    #
<%= indent %>    # You usually want this. Really. Keep it there.
<%= indent %>    it { is_self_contained }

<%= indent %>    # If you really really want to allow some definitions to NOT be self-contained
<%= indent %>    # (but you really do not, trust me), you can call assert_is_self_contained with
<%= indent %>    # specific definitions
<%= indent %>    # it "has only a_def self-contained" do
<%= indent %>    #    assert_is_self_contained a_def
<%= indent %>    # end

<%= indent %>    # Test if all definitions can be instanciated, i.e. are
<%= indent %>    # well-formed networks with no data services
<%= indent %>    #
<%= indent %>    # In principle you could remove the self-contained test above, but that
<%= indent %>    # would mean that, were you to disable this test you would not check for
<%= indent %>    # the profile being self-contained. And that's a bad idea. Keep both.
<%= indent %>    it { can_instanciate }

<%= indent %>    # If only parts of the profile should be instanciated, you can 
<%= indent %>    # call assert_can_instanciate with specific definitions
<%= indent %>    # it { can_instanciate a_def }

<%= indent %>    # call assert_can_instanciate with specific definitions
<%= indent %>    # it { can_instanciate a_def }

<%= indent %>    # Test if specific definitions can be deployed, i.e. are ready to be
<%= indent %>    # started. You want this on the "final" profiles (i.e. the definitions
<%= indent %>    # you will actually on the robot)
<%= indent %>    #
<%= indent %>    # In principle you could avoid testing for instanciation and/or
<%= indent %>    # self-contained properties, but it is advisable to keep them.
<%= indent %>    # Were you to disable this test you would not check for
<%= indent %>    # them anymore. And that's a bad idea. Keep all.
<%= indent %>    it { can_deploy }

<%= indent %>    # If only parts of the profile should be deployd, you can 
<%= indent %>    # call assert_can_deploy with specific definitions
<%= indent %>    # it { can_deploy a_def }

<%= indent %>    # If you want to verify properties when some actions are present in the same network
<%= indent %>    # use the _together variants:
<%= indent %>    # it { can_instanciate_together a_def, another_def }
<%= indent %>    # it { can_deploy_together a_def, another_def }

<%= indent %>    # See the documentation of Syskit::Test::ProfileAssertions for more
<%= indent %>end
<%= close %>
