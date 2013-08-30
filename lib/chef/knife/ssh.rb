#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2009 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/knife'

class Chef
  class Knife
    class Ssh < Knife

      deps do
        require 'net/ssh'
        require 'net/ssh/multi'
        require 'chef/monkey_patches/net-ssh-multi'
        require 'readline'
        require 'chef/exceptions'
        require 'chef/search/query'
        require 'chef/mixin/shell_out'
        require 'mixlib/shellout'
      end

      include Chef::Mixin::ShellOut

      attr_writer :password

      banner "knife ssh QUERY COMMAND (options)"

      option :concurrency,
        :short => "-C NUM",
        :long => "--concurrency NUM",
        :description => "The number of concurrent connections",
        :default => nil,
        :proc => lambda { |o| o.to_i }

      option :attribute,
        :short => "-a ATTR",
        :long => "--attribute ATTR",
        :description => "The attribute to use for opening the connection - default depends on the context",
        :proc => Proc.new { |key| Chef::Config[:knife][:ssh_attribute] = key.strip }

      option :manual,
        :short => "-m",
        :long => "--manual-list",
        :boolean => true,
        :description => "QUERY is a space separated list of servers",
        :default => false

      option :ssh_user,
        :short => "-x USERNAME",
        :long => "--ssh-user USERNAME",
        :description => "The ssh username"

      option :ssh_password,
        :short => "-P PASSWORD",
        :long => "--ssh-password PASSWORD",
        :description => "The ssh password"

      option :ssh_port,
        :short => "-p PORT",
        :long => "--ssh-port PORT",
        :description => "The ssh port",
        :proc => Proc.new { |key| Chef::Config[:knife][:ssh_port] = key.strip }

      option :ssh_gateway,
        :short => "-G GATEWAY",
        :long => "--ssh-gateway GATEWAY",
        :description => "The ssh gateway",
        :proc => Proc.new { |key| Chef::Config[:knife][:ssh_gateway] = key.strip }

      option :forward_agent,
        :short => "-A",
        :long => "--forward-agent",
        :description => "Enable SSH agent forwarding",
        :boolean => true

      option :identity_file,
        :short => "-i IDENTITY_FILE",
        :long => "--identity-file IDENTITY_FILE",
        :description => "The SSH identity file used for authentication"

      option :host_key_verify,
        :long => "--[no-]host-key-verify",
        :description => "Verify host key, enabled by default.",
        :boolean => true,
        :default => true

      def session
        config[:on_error] ||= :skip
        ssh_error_handler = Proc.new do |server|
          if config[:manual]
            node_name = server.host
          else
            @action_nodes.each do |n|
              node_name = n if format_for_display(n)[config[:attribute]] == server.host
            end
          end
          case config[:on_error]
          when :skip
            ui.warn "Failed to connect to #{node_name} -- #{$!.class.name}: #{$!.message}"
            $!.backtrace.each { |l| Chef::Log.debug(l) }
          when :raise
            #Net::SSH::Multi magic to force exception to be re-raised.
            throw :go, :raise
          end
        end

        @session ||= Net::SSH::Multi.start(:concurrent_connections => config[:concurrency], :on_error => ssh_error_handler)
      end

      def configure_gateway
        config[:ssh_gateway] ||= Chef::Config[:knife][:ssh_gateway]
        if config[:ssh_gateway]
          gw_host, gw_user = config[:ssh_gateway].split('@').reverse
          gw_host, gw_port = gw_host.split(':')
          gw_opts = gw_port ? { :port => gw_port } : {}

          session.via(gw_host, gw_user || config[:ssh_user], gw_opts)
        end
      rescue Net::SSH::AuthenticationFailed
        user = gw_user || config[:ssh_user]
        prompt = "Enter the password for #{user}@#{gw_host}: "
        gw_opts.merge!(:password => prompt_for_password(prompt))
        session.via(gw_host, user, gw_opts)
      end

      def configure_session
        list = case config[:manual]
               when true
                 @name_args[0].split(" ")
               when false
                 r = Array.new
                 q = Chef::Search::Query.new
                 @action_nodes = q.search(:node, @name_args[0])[0]
                 @action_nodes.each do |item|
                   # we should skip the loop to next iteration if the item returned by the search is nil
                   next if item.nil?
                   # if a command line attribute was not passed, and we have a cloud public_hostname, use that.
                   # see #configure_attribute for the source of config[:attribute] and config[:override_attribute]
                   if !config[:override_attribute] && item[:cloud] and item[:cloud][:public_hostname]
                     i = item[:cloud][:public_hostname]
                   elsif config[:override_attribute]
                     i = extract_nested_value(item, config[:override_attribute])
                   else
                     i = extract_nested_value(item, config[:attribute])
                   end
                   # next if we couldn't find the specified attribute in the returned node object
                   next if i.nil?
                   r.push(i)
                 end
                 r
               end
        if list.length == 0
          if @action_nodes.length == 0
            ui.fatal("No nodes returned from search!")
          else
            ui.fatal("#{@action_nodes.length} #{@action_nodes.length > 1 ? "nodes":"node"} found, " +
                     "but does not have the required attribute to establish the connection. " +
                     "Try setting another attribute to open the connection using --attribute.")
          end
          exit 10
        end
        session_from_list(list)
      end

      def session_from_list(list)
        list.each do |item|
          Chef::Log.debug("Adding #{item}")
          session_opts = {}

          ssh_config = Net::SSH.configuration_for(item)

          # Chef::Config[:knife][:ssh_user] is parsed in #configure_user and written to config[:ssh_user]
          user = config[:ssh_user] || ssh_config[:user]
          hostspec = user ? "#{user}@#{item}" : item
          session_opts[:keys] = File.expand_path(config[:identity_file]) if config[:identity_file]
          session_opts[:keys_only] = true if config[:identity_file]
          session_opts[:password] = config[:ssh_password] if config[:ssh_password]
          session_opts[:forward_agent] = config[:forward_agent]
          session_opts[:port] = config[:ssh_port] || Chef::Config[:knife][:ssh_port] || ssh_config[:port]
          session_opts[:logger] = Chef::Log.logger if Chef::Log.level == :debug

          if !config[:host_key_verify]
            session_opts[:paranoid] = false
            session_opts[:user_known_hosts_file] = "/dev/null"
          end

          session.use(hostspec, session_opts)

          @longest = item.length if item.length > @longest
        end

        session
      end

      def fixup_sudo(command)
        command.sub(/^sudo/, 'sudo -p \'knife sudo password: \'')
      end

      def print_data(host, data)
        @buffers ||= {}
        if leftover = @buffers[host]
          @buffers[host] = nil
          print_data(host, leftover + data)
        else
          if newline_index = data.index("\n")
            line = data.slice!(0...newline_index)
            data.slice!(0)
            print_line(host, line)
            print_data(host, data)
          else
            @buffers[host] = data
          end
        end
      end

      def print_line(host, data)
        padding = @longest - host.length
        str = ui.color(host, :cyan) + (" " * (padding + 1)) + data
        ui.msg(str)
      end

      def ssh_command(command, subsession=nil)
        exit_status = 0
        subsession ||= session
        command = fixup_sudo(command)
        command.force_encoding('binary') if command.respond_to?(:force_encoding)
        subsession.open_channel do |ch|
          ch.request_pty
          ch.exec command do |ch, success|
            raise ArgumentError, "Cannot execute #{command}" unless success
            ch.on_data do |ichannel, data|
              print_data(ichannel[:host], data)
              if data =~ /^knife sudo password: /
                print_data(ichannel[:host], "\n")
                ichannel.send_data("#{get_password}\n")
              end
            end
            ch.on_request "exit-status" do |ichannel, data|
              exit_status = [exit_status, data.read_long].max
            end
          end
        end
        session.loop
        exit_status
      end

      def get_password
        @password ||= prompt_for_password
      end

      def prompt_for_password(prompt = "Enter your password: ")
        ui.ask(prompt) { |q| q.echo = false }
      end

      # Present the prompt and read a single line from the console. It also
      # detects ^D and returns "exit" in that case. Adds the input to the
      # history, unless the input is empty. Loops repeatedly until a non-empty
      # line is input.
      def read_line
        loop do
          command = reader.readline("#{ui.color('knife-ssh>', :bold)} ", true)

          if command.nil?
            command = "exit"
            puts(command)
          else
            command.strip!
          end

          unless command.empty?
            return command
          end
        end
      end

      def reader
        Readline
      end

      def interactive
        puts "Connected to #{ui.list(session.servers_for.collect { |s| ui.color(s.host, :cyan) }, :inline, " and ")}"
        puts
        puts "To run a command on a list of servers, do:"
        puts "  on SERVER1 SERVER2 SERVER3; COMMAND"
        puts "  Example: on latte foamy; echo foobar"
        puts
        puts "To exit interactive mode, use 'quit!'"
        puts
        while 1
          command = read_line
          case command
          when 'quit!'
            puts 'Bye!'
            break
          when /^on (.+?); (.+)$/
            raw_list = $1.split(" ")
            server_list = Array.new
            session.servers.each do |session_server|
              server_list << session_server if raw_list.include?(session_server.host)
            end
            command = $2
            ssh_command(command, session.on(*server_list))
          else
            ssh_command(command)
          end
        end
      end

      def screen
        tf = Tempfile.new("knife-ssh-screen")
        if File.exist? "#{ENV["HOME"]}/.screenrc"
          tf.puts("source #{ENV["HOME"]}/.screenrc")
        end
        tf.puts("caption always '%-Lw%{= BW}%50>%n%f* %t%{-}%+Lw%<'")
        tf.puts("hardstatus alwayslastline 'knife ssh #{@name_args[0]}'")
        window = 0
        session.servers_for.each do |server|
          tf.print("screen -t \"#{server.host}\" #{window} ssh ")
          tf.print("-i #{config[:identity_file]} ") if config[:identity_file]
          server.user ? tf.puts("#{server.user}@#{server.host}") : tf.puts(server.host)
          window += 1
        end
        tf.close
        exec("screen -c #{tf.path}")
      end

      def tmux_split(use_panes)
        tmux_name = "'knife ssh #{@name_args[0].gsub(/:/,'=')}'"
        first_window_name = nil
        tmux_ssh_command = lambda do |server|
          identity = "-i #{config[:identity_file]} " if config[:identity_file]
          prefix = server.user ? "#{server.user}@" : ""
          "'ssh #{identity}#{prefix}#{server.host}'"
        end

        rename_window = lambda do |pane_start, pane_end|
          if pane_start == pane_end
            window_name = "'host #{pane_start}'"
          else
            window_name = "'hosts #{pane_start}-#{pane_end}'"
          end
          first_window_name ||= window_name
          shell_out!("tmux rename-window -t #{tmux_name} #{window_name}")
        end

        begin
          tmux_opts = Chef::Config[:knife][:ssh_tmux] || {}
          # Default panes to use 'tiled' layout as this will allow for the highest
          # number of panes per window
          pane_layout = tmux_opts.fetch(:pane_layout, "tiled")
          use_panes = use_panes || tmux_opts.fetch(:use_panes, false)
          sync_panes = tmux_opts.fetch(:sync_panes, true)
          sync_panes_keybind = tmux_opts.fetch(:sync_panes_key, "s")
          sync_panes_state = sync_panes ? "on" : "off"

          # Track the first window name - so we can get back to it.
          # if we're using panes we'll have to figure out this name,
          # since we will be renaming the window
          first = session.servers_for.first
          first_window_name = "'#{first.host}'" unless use_panes

          command = []
          # Create an initial session and start it with the first ssh request.
          command << "tmux new-session -d -n '#{first.host}' -s #{tmux_name}  #{tmux_ssh_command.call(first)}"
          # we'll set meaningful window names ourselves, don't let tmux try to figure it out.
          command << "setw automatic-rename off"
          command << "setw allow-rename off"
          if use_panes
            command << "setw synchronize-panes #{sync_panes_state}"
            command << "bind-key #{sync_panes_keybind} set synchronize-panes"
            # We will display an info message about the 's' key binding. Give the user time to see it.
            # This also has the side effect of helping our final 'refresh-client' command to work correctly
            # in clearing out artifacts that may result from rapid creation of a potentially large number of
            # panes.
            command << "set display-time 3000"
          end
          shell_out!(command.join(" \\; "))
          if session.servers_for.size > 1
            pane_start = 1
            pane_count = 1
            session.servers_for[1..-1].map do |server|
              tmuxcmd = "-t #{tmux_name} #{tmux_ssh_command.call(server)}"
              if use_panes
                # Issuing a select-layout command after each split-window will force tmux
                # to rebalance the panes - ensuring we can fit the maximum number of panes in
                # each window.
                response = shell_out("tmux split-window #{tmuxcmd} \\; select-layout #{pane_layout}")
                if response.exitstatus > 0
                  # failure to split-window means it was already split too many times. Set a meaninful name
                  # for this window and then create a new one.
                  rename_window.call(pane_start, pane_count)
                  pane_start = pane_count + 1
                  command = []
                  command << "tmux new-window -t #{tmux_name} -n '#{server.host}' #{tmux_ssh_command.call(server)}"
                  command << "setw synchronize-panes #{sync_panes_state}"
                  shell_out!(command.join(" \\; "))
                end
                pane_count = pane_count + 1
              else
                # If we're not using panes, just add a new window for each session.
                shell_out!("tmux new-window -t #{tmux_name} -n '#{server.host}' #{tmux_ssh_command.call(server)}")
              end
            end
          end
          rename_window.call(pane_start, pane_count) if use_panes
          command = []
          command << "tmux attach-session -t #{tmux_name}"
          command << "select-window -t #{first_window_name}"
          command << "display-message 'use PREFIX + #{sync_panes_keybind} to toggle synchronized panes'" if use_panes
          # Sometimes artifacts appeared in testing - this tends to clear them
          command << "refresh-client"
          exec(command.join(" \\; "))
        rescue Chef::Exceptions::Exec
        end
      end

      def macterm
        begin
          require 'appscript'
        rescue LoadError
          STDERR.puts "you need the rb-appscript gem to use knife ssh macterm. `(sudo) gem install rb-appscript` to install"
          raise
        end

        Appscript.app("/Applications/Utilities/Terminal.app").windows.first.activate
        Appscript.app("System Events").application_processes["Terminal.app"].keystroke("n", :using=>:command_down)
        term = Appscript.app('Terminal')
        window = term.windows.first.get

        (session.servers_for.size - 1).times do |i|
          window.activate
          Appscript.app("System Events").application_processes["Terminal.app"].keystroke("t", :using=>:command_down)
        end

        session.servers_for.each_with_index do |server, tab_number|
          cmd = "unset PROMPT_COMMAND; echo -e \"\\033]0;#{server.host}\\007\"; ssh #{server.user ? "#{server.user}@#{server.host}" : server.host}"
          Appscript.app('Terminal').do_script(cmd, :in => window.tabs[tab_number + 1].get)
        end
      end

      def configure_attribute
        # Setting 'knife[:ssh_attribute] = "foo"' in knife.rb => Chef::Config[:knife][:ssh_attribute] == 'foo'
        # Running 'knife ssh -a foo' => both Chef::Config[:knife][:ssh_attribute] && config[:attribute] == foo
        # Thus we can differentiate between a config file value and a command line override at this point by checking config[:attribute]
        # We can tell here if fqdn was passed from the command line, rather than being the default, by checking config[:attribute]
        # However, after here, we cannot tell these things, so we must preserve config[:attribute]
        config[:override_attribute] = config[:attribute] || Chef::Config[:knife][:ssh_attribute]
        config[:attribute] = (Chef::Config[:knife][:ssh_attribute] ||
                              config[:attribute] ||
                              "fqdn").strip
      end

      def cssh
        cssh_cmd = nil
        %w[csshX cssh].each do |cmd|
          begin
            # Unix and Mac only
            cssh_cmd = shell_out!("which #{cmd}").stdout.strip
            break
          rescue Mixlib::ShellOut::ShellCommandFailed
          end
        end
        raise Chef::Exceptions::Exec, "no command found for cssh" unless cssh_cmd

        session.servers_for.each do |server|
          cssh_cmd << " #{server.user ? "#{server.user}@#{server.host}" : server.host}"
        end
        Chef::Log.debug("starting cssh session with command: #{cssh_cmd}")
        exec(cssh_cmd)
      end

      def get_stripped_unfrozen_value(value)
        return nil if value.nil?
        value.strip
      end

      def configure_user
        config[:ssh_user] = get_stripped_unfrozen_value(config[:ssh_user] ||
                             Chef::Config[:knife][:ssh_user])
      end

      def configure_identity_file
        config[:identity_file] = get_stripped_unfrozen_value(config[:identity_file] ||
                             Chef::Config[:knife][:ssh_identity_file])
      end

      def extract_nested_value(data_structure, path_spec)
        ui.presenter.extract_nested_value(data_structure, path_spec)
      end

      def run
        extend Chef::Mixin::Command

        @longest = 0

        configure_attribute
        configure_user
        configure_identity_file
        configure_gateway
        configure_session

        exit_status =
        case @name_args[1]
        when "interactive"
          interactive
        when "screen"
          screen
        when "tmux-split"
          # use tmux with split-windows enabled
          tmux_split true
        when "tmux"
          # use tmux with split-windows disabled unless otherwise specified
          # in user's knife config
          tmux_split false
        when "macterm"
          macterm
        when "cssh"
          cssh
        when "csshx"
          Chef::Log.warn("knife ssh csshx will be deprecated in a future release")
          Chef::Log.warn("please use knife ssh cssh instead")
          cssh
        else
          ssh_command(@name_args[1..-1].join(" "))
        end

        session.close
        if exit_status != 0
          exit exit_status
        else
          exit_status
        end
      end

    end
  end
end
