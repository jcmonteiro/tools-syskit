require 'syskit'
require 'roby/interface/async'
require 'roby/interface/async/log'
require 'syskit/gui/job_status_display'

module Syskit
    module GUI
        # UI that displays and allows to control jobs
        class RuntimeState < Qt::Widget
            # @return [Roby::Interface::Async::Interface] the underlying syskit
            #   interface
            attr_reader :syskit
            # An async object to access the log stream
            attr_reader :syskit_log_stream

            # The toplevel layout
            attr_reader :main_layout
            # The layout used to organize the widgets to create new jobs
            attr_reader :new_job_layout
            # The layout used to organize the running jobs
            attr_reader :job_control_layout
            # The combo box used to create new jobs
            attr_reader :action_combo

            class ActionListDelegate < Qt::StyledItemDelegate
                OUTER_MARGIN = 5
                INTERLINE    = 3
                def sizeHint(option, index)
                    fm = option.font_metrics
                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    Qt::Size.new(
                        [fm.width(main), fm.width(doc)].max + 2 * OUTER_MARGIN,
                        fm.height * 2 + OUTER_MARGIN * 2 + INTERLINE)
                end

                def paint(painter, option, index)
                    painter.save

                    if (option.state & Qt::Style::State_Selected) != 0
                        painter.fill_rect(option.rect, option.palette.highlight)
                        painter.brush = option.palette.highlighted_text
                    end

                    main = index.data.toString
                    doc = index.data(Qt::UserRole).to_string || ''
                    text_bounds = Qt::Rect.new

                    fm = option.font_metrics
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, option.rect.y + OUTER_MARGIN, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, main, text_bounds)

                    font = painter.font
                    font.italic = true
                    painter.font = font
                    painter.draw_text(
                        Qt::Rect.new(option.rect.x + OUTER_MARGIN, text_bounds.bottom + INTERLINE, option.rect.width - 2 * OUTER_MARGIN, fm.height),
                        Qt::AlignLeft, doc, text_bounds)
                ensure
                    painter.restore
                end
            end

            # @param [Roby::Interface::Async::Interface] syskit the underlying
            #   syskit interface
            # @param [Integer] poll_period how often should the syskit interface
            #   be polled (milliseconds). Set to nil if the polling is already
            #   done externally
            def initialize(parent:nil, syskit: Roby::Interface::Async::Interface.new, poll_period: 10)
                super(parent)

                if poll_period
                    poll_syskit_interface(syskit, poll_period)
                end

                create_ui

                @syskit = syskit
                syskit.on_reachable do
                    update_log_server_connection(syskit.client.log_server_port)
                    action_combo.clear
                    syskit.actions.sort_by(&:name).each do |action|
                        next if action.advanced?
                        action_combo.add_item(action.name, Qt::Variant.new(action.doc))
                    end
                    emit connection_state_changed(true)
                end
                syskit.on_unreachable do
                    emit connection_state_changed(false)
                end
                syskit.on_job do |job|
                    job.start
                    monitor_job(job)
                end
            end

            def update_log_server_connection(port)
                if syskit_log_stream && (syskit_log_stream.port == port)
                    return
                elsif syskit_log_stream
                    syskit_log_stream.close
                end
                @syskit_log_stream = Roby::Interface::Async::Log.new(syskit.remote_name, port: port)
                syskit_log_stream.on_update do |cycle_index, cycle_time|
                    emit updated(cycle_index, Qt::DateTime.new(cycle_time))
                end
            end

            signals 'updated(int, QDateTime)'
            signals 'connection_state_changed(bool)'

            def remote_name
                syskit.remote_name
            end

            def create_ui
                main_layout = Qt::VBoxLayout.new(self)
                main_layout.add_layout(@new_job_layout = new_job_ui)
                main_layout.add_layout(@job_control_layout = job_control_ui)
                main_layout.add_stretch(1)
            end

            def job_control_ui
                job_control_layout = Qt::VBoxLayout.new
                job_control_layout
            end

            def new_job_ui
                new_job_layout = Qt::HBoxLayout.new
                label   = Qt::Label.new("New Job", self)
                @action_combo = Qt::ComboBox.new(self)
                action_combo.item_delegate = ActionListDelegate.new(self)
                new_job_layout.add_widget label
                new_job_layout.add_widget action_combo, 1
                action_combo.connect(SIGNAL('activated(QString)')) do |action_name|
                    create_new_job(action_name)
                end
                new_job_layout
            end

            class NewJobDialog < Qt::Dialog
                attr_reader :editor

                def initialize(parent = nil, text = '')
                    super(parent)
                    layout = Qt::VBoxLayout.new(self)
                    @editor = Qt::TextEdit.new(self)
                    layout.add_widget editor
                    self.text = text
                end

                def self.exec(parent, text)
                    new(parent, text).exec
                end

                def text=(text)
                    editor.plain_text = text
                end

                def text
                    editor.plain_text
                end
            end

            def create_new_job(action_name)
                action_model = syskit.actions.find { |m| m.name == action_name }
                if !action_model
                    raise ArgumentError, "no action named #{action_name} found"
                end

                if action_model.arguments.empty?
                    syskit.client.send("#{action_name}!", Hash.new)
                else
                    formatted_action = Array.new
                    formatted_action << "#{action_name}("
                    action_model.arguments.each do |arg|
                        formatted_action << "  # #{arg.doc}"
                        formatted_action << "  #{arg.name}: #{arg.default},"
                    end
                    formatted_action << ")"
                    NewJobDialog.exec(self, formatted_action.join("\n"))
                end
            end

            attr_reader :syskit_poll

            # @api private
            #
            # Sets up polling on a given syskit interface
            def poll_syskit_interface(syskit, period)
                @syskit_poll = Qt::Timer.new
                syskit_poll.connect(SIGNAL('timeout()')) do
                    syskit.poll
                    if syskit_log_stream
                        syskit_log_stream.poll
                    end
                end
                syskit_poll.start(period)
                syskit
            end

            # @api private
            #
            # Create the UI elements for the given job
            #
            # @param [Roby::Interface::Async::JobMonitor] job
            def monitor_job(job)
                job_status = JobStatusDisplay.new(job, self)
                connect(job_status, SIGNAL('fileOpenClicked(const QUrl&)'),
                        self, SIGNAL('fileOpenClicked(const QUrl&)'))
                job_control_layout.add_widget job_status
            end

            signals 'fileOpenClicked(const QUrl&)'
        end
    end
end

