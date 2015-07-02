# -*- coding: utf-8 -*-
#  Copyright 2012 Takeshi KOMIYA
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

require "find"
require "json"
require "tempfile"
require "capistrano-paratrooper-chef/tar_writer"
require "capistrano-paratrooper-chef/version"
require "capistrano-paratrooper-chef/dsl"


Capistrano::Configuration.instance.load do
  namespace :paratrooper do
    # directory structure of chef-kitchen
    set :chef_kitchen_path, "config"
    set :chef_default_solo_json_path, "solo.json"
    set :chef_nodes_path, "nodes"
    set :chef_cookbooks_path, ["site-cookbooks"]
    set :chef_vendor_cookbooks_path, "vendor/cookbooks"
    set :chef_roles_path, "roles"
    set :chef_environment, nil
    set :chef_environment_path, "environments"
    set :chef_databags_path, "data_bags"
    set :chef_databag_secret, "data_bag_key"

    # remote chef settings
    set :chef_solo_path, "chef-solo"
    set(:chef_working_dir) {
      capture("echo $HOME").strip + "/chef-solo"
    }
    set :chef_cache_dir, "/var/chef/cache"
    set(:chef_use_sudo) {
      capture("id -u").to_i != 0
    }

    # chef settings
    set :chef_roles_auto_discovery, false
    set :chef_verbose_logging, true
    set :chef_debug, false

    def sudocmd
      envvars = fetch(:default_environment, {}).collect{|k, v| "#{k}=#{v}"}

      begin
        old_sudo = self[:sudo]
        if fetch(:rvm_type, nil) == :user
          self[:sudo] = "rvmsudo_secure_path=1 #{File.join(rvm_bin_path, "rvmsudo")}"
        end

        if fetch(:chef_use_sudo)
          cmd = top.sudo
        else
          cmd = ""
        end

        if envvars
          cmd += " env #{envvars.join(" ")}"
        end
      ensure
        self[:sudo] = old_sudo  if old_sudo
      end

      cmd
    end

    def sudo(command, *args)
      run "#{sudocmd} #{command}", *args
    end

    def remote_path(*path)
      File.join(fetch(:chef_working_dir), *path)
    end

    def cookbooks_paths
      dirs = [fetch(:chef_cookbooks_path), fetch(:chef_vendor_cookbooks_path)].flatten
      dirs.collect{|path| File.join(fetch(:chef_kitchen_path), path)}
    end

    def vendor_cookbooks_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_vendor_cookbooks_path))
    end

    def roles_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_roles_path))
    end

    def role_exists?(name)
      File.exist?(File.join(roles_path, name.to_s + ".json")) ||
      File.exist?(File.join(roles_path, name.to_s + ".rb"))
    end

    def environment_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_environment_path))
    end

    def databags_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_databags_path))
    end

    def databag_secret_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_databag_secret))
    end

    def nodes_path
      File.join(fetch(:chef_kitchen_path), fetch(:chef_nodes_path))
    end


    namespace :run_list do
      def solo_json_paths_for(name)
        [File.join(nodes_path, name.to_s + ".json"),
         File.join(fetch(:chef_kitchen_path), fetch(:chef_default_solo_json_path))]
      end

      def discover
        find_servers_for_task(current_task).each do |server|
          server.options[:chef_attributes] ||= {}
          solo_json_paths = solo_json_paths_for(server.host)
          solo_json_paths.each do |path|
            next  if not File.exist?(path)

            begin
              open(path) do |fd|
                server.options[:chef_attributes] = JSON.load(fd).merge(server.options[:chef_attributes])

                if server.options[:chef_attributes]["run_list"].nil?
                  server.options[:chef_attributes]["run_list"] = []
                end
              end
              break
            rescue JSON::ParserError
              logger.important("Could not parse JSON file: %s" % path)
            rescue => e
              logger.important("Could not read JSON file: %s" % e)
            end
          end

          if server.options[:chef_attributes].empty?
            logger.important("any JSON file not found: %s" % solo_json_paths.inspect)
          end

          if server.options[:chef_attributes]["run_list"].nil?
            server.options[:chef_attributes]["run_list"] = []
          end

        if fetch(:chef_roles_auto_discovery)
            role_names_for_host(server).each do |role|
              server.options[:chef_attributes]["run_list"] << "role[#{role}]"  if role_exists?(role)
            end
          end
        end
      end

      def discovered_attributes
        find_servers_for_task(current_task).collect{|server| server.options[:chef_attributes]}.compact
      end

      def discovered_lists
        discovered_attributes.collect{|attr| attr["run_list"]}
      end

      def unique?
        if fetch(:chef_roles_auto_discovery)
          discovered_lists.uniq.size == 1
        else
          true
        end
      end

      def ensure
        if discovered_lists.all?{|run_list| run_list.empty?}
          abort "You must specify at least one recipe or role"
        end
      end
    end

    namespace :chef do
      task :default do
        before_execute
        chef.execute
      end

      task :why_run do
        before_execute
        chef.execute_why_run
      end

      task :before_execute do
        run_list.discover
        run_list.ensure
        kitchen.ensure_cookbooks
        kitchen.ensure_working_dir
        kitchen.upload
        chef.generate_solo_rb
        chef.generate_solo_json
      end

      task :solo do
        chef.default
      end

      def generate_solo_rb
        config = <<-CONF
          root = File.expand_path(File.dirname(__FILE__))
          file_cache_path #{fetch(:chef_cache_dir).inspect}
          cookbook_path #{kitchen.cookbooks_paths.inspect}.collect{|dir| File.join(root, dir)}
          role_path File.join(root, #{kitchen.roles_path.inspect})
          environment #{fetch(:chef_environment).to_s.inspect}
          environment_path File.join(root, #{kitchen.environment_path.inspect})
          data_bag_path File.join(root, #{kitchen.databags_path.inspect})
          verbose_logging #{fetch(:chef_verbose_logging)}
        CONF
        if File.exist?(kitchen.databag_secret_path)
          config += <<-CONF
          encrypted_data_bag_secret File.join(root, #{kitchen.databag_secret_path.inspect})
          CONF
        end

        put config, remote_path("solo.rb"), :via => :scp
      end

      def generate_solo_json
        find_servers_for_task(current_task).each do |server|
          put server.options[:chef_attributes].to_json, remote_path("solo.json"), :hosts => server.host, :via => :scp
        end
      end

      desc "Run chef-solo"
      task :execute do
        logger.info "Now running chef-solo"
        command = "#{chef_solo_path} -c #{remote_path("solo.rb")} -j #{remote_path("solo.json")}#{' -l debug' if fetch(:chef_debug)}"
        if run_list.unique?
          sudo command
        else
          parallel do |session|
            session.when "options[:chef_attributes]['run_list'].size > 0",
              "#{sudocmd} #{command}"
          end
        end
      end

      desc "why-run chef-solo"
      task :execute_why_run do
        logger.info "Now running why-run chef-solo"
        command = "#{chef_solo_path} -c #{remote_path("solo.rb")} -j #{remote_path("solo.json")} -l fatal --why-run"
        if run_list.unique?
          sudo command
        else
          parallel do |session|
            session.when "options[:chef_attributes]['run_list'].size > 0",
              "#{sudocmd} #{command}"
          end
        end
      end
    end

    namespace :kitchen do
      namespace :berkshelf do
        def fetch
          require 'berkshelf'

          if File.exist? 'Berksfile'
            logger.debug("executing berkshelf")
            berksfile = Berkshelf::Berksfile.from_file('Berksfile')
            if berksfile.respond_to?(:vendor)
              FileUtils.rm_rf(vendor_cookbooks_path)
              FileUtils.mkdir_p(File.dirname(vendor_cookbooks_path))
              berksfile.vendor(vendor_cookbooks_path)
            else
              berksfile.install(:path => vendor_cookbooks_path)
            end
          end
        rescue LoadError
          # pass
        end
      end

      namespace :librarian_chef do
        def fetch
          require 'librarian/action'
          require 'librarian/chef'

          if File.exist? 'Cheffile'
            logger.debug("executing librarian-chef")
            Librarian::Action::Resolve.new(librarian_env).run
            Librarian::Action::Install.new(librarian_env).run
          end
        rescue LoadError
          # pass
        end

        def librarian_env
          @librarian_env ||= Librarian::Chef::Environment.new
          @librarian_env.config_db.local["path"] = vendor_cookbooks_path
          @librarian_env
        end
      end

      def ensure_cookbooks
        abort "No cookbooks found in #{fetch(:cookbooks_directory).inspect}" if kitchen.cookbooks_paths.empty?
        abort "Multiple cookbook definitions found: Cheffile, Berksfile" if File.exist? 'Cheffile' and File.exist? 'Berksfile'
      end

      def ensure_working_dir
        run "rm -rf #{fetch(:chef_working_dir)} && mkdir -p #{fetch(:chef_working_dir)}"
        sudo "mkdir -p #{fetch(:chef_cache_dir)}"
      end

      desc "Upload files in kitchen"
      task :upload do
        berkshelf.fetch
        librarian_chef.fetch

        stream = StringIO.new
        TarWriter.new(stream) do |writer|
          paths = [cookbooks_paths, roles_path, environment_path, databags_path, databag_secret_path]
          kitchen_paths = paths.flatten.compact.select{|d| File.exists?(d)}
          Find.find(*kitchen_paths) do |path|
            writer.add(path)
          end
        end

        stream.seek(0)
        put stream.read, remote_path("kitchen.tar"), :via => :scp
        run "cd #{fetch(:chef_working_dir)} && tar -xf kitchen.tar"
      end
    end
  end
end
