# frozen_string_literal: true

module Drivers
  module Webserver
    class Apache2 < Drivers::Webserver::Base
      adapter :apache2
      allowed_engines :apache2
      packages debian: 'apache2', rhel: %w[httpd24 mod24_ssl]
      output filter: %i[
        dhparams keepalive_timeout limit_request_body log_dir log_level proxy_timeout
        ssl_for_legacy_browsers extra_config extra_config_ssl port ssl_port
      ]
      notifies :deploy,
               action: :reload, resource: { debian: 'service[apache2]', rhel: 'service[httpd]' }, timer: :delayed
      notifies :undeploy,
               action: :reload, resource: { debian: 'service[apache2]', rhel: 'service[httpd]' }, timer: :delayed
      log_paths lambda { |context|
        %w[access.log error.log].map do |log_type|
          File.join(context.raw_out[:log_dir], "#{context.app[:domains].first}.#{log_type}")
        end
      }

      def self.passenger_supported?
        true
      end

      def settings
        output = super.merge(
          log_dir: node['deploy'][app['shortname']][driver_type]['log_dir'] || "/var/log/#{service_name}"
        )
        output[:extra_config_ssl] = output[:extra_config] if output[:extra_config_ssl] == true
        output
      end

      def setup
        handle_packages
        enable_modules(%w[expires headers lbmethod_byrequests proxy proxy_balancer proxy_http rewrite ssl])
        install_mod_passenger if passenger?
        add_sites_available_enabled
        define_service(:start)
      end

      def configure
        define_service
        add_ssl_directory
        add_ssl_item(:private_key)
        add_ssl_item(:certificate)
        add_ssl_item(:chain)
        add_dhparams

        remove_defaults
        add_appserver_config
        enable_appserver_config
        super
      end

      def before_deploy
        define_service
      end
      alias before_undeploy before_deploy

      def conf_dir
        File.join('/', 'etc', node['platform_family'] == 'debian' ? 'apache2' : 'httpd')
      end

      def service_name
        node['platform_family'] == 'debian' ? 'apache2' : 'httpd'
      end

      private

      def remove_defaults
        conf_path = conf_dir
        (node['defaults']['webserver']['remove_default_sites'] || []).each do |file|
          notifying_file "#{conf_path}/sites-enabled/#{file}", :reload do
            action :delete
          end
        end
      end

      def add_sites_available_enabled
        return if node['platform_family'] == 'debian'

        context.directory "#{conf_dir}/sites-available" do
          mode '0755'
        end
        context.directory "#{conf_dir}/sites-enabled" do
          mode '0755'
        end

        context.execute 'echo "IncludeOptional sites-enabled/*.conf" >> /etc/httpd/conf/httpd.conf'
      end

      def enable_modules(modules = [])
        return unless node['platform_family'] == 'debian'
        modules.each { |mod| enable_module(mod) }
      end

      def enable_module(mod)
        notifying_execute "Enable Apache2 module #{mod}" do
          command "a2enmod #{mod}"
          not_if "a2query -m #{mod}"
        end
      end

      def install_mod_passenger
        unless node['platform_family'] == 'debian'
          raise(ArgumentError, 'passenger appserver only supported on Debian/Ubuntu')
        end
        mod_passenger_packages
      end

      def mod_passenger_packages
        enable_mod_passenger_repo(context)
        ver = node['defaults']['appserver']['passenger_version']
        notifying_package 'libapache2-mod-passenger' do
          version ver unless ver.nil?
        end
      end

      def add_appserver_config
        a = Drivers::Appserver::Factory.build(context, app)
        opts = { application: app, deploy_dir: deploy_dir(app), out: out, conf_dir: conf_dir, adapter: adapter,
                 name: a.adapter, deploy_env: deploy_env, appserver_config: a.webserver_config_params }
        return unless Drivers::Appserver::Base.adapters.include?(opts[:name])
        generate_appserver_config(opts, site_config_template(opts[:name]), site_config_template_cookbook)
        generate_appserver_extra_config_dir(opts)
      end

      def generate_appserver_extra_config_dir(opts)
        context.directory "#{opts[:conf_dir]}/sites-available/#{app['shortname']}.conf.d" do
          recursive false
          user 'root'
          group 'root'
          mode '0644'
          action :create
          only_if { !::File.directory?("#{opts[:conf_dir]}/sites-available/#{app['shortname']}.conf.d") }
        end
      end

      def appserver_site_config_template(appserver_adapter)
        case appserver_adapter
        when 'passenger'
          "appserver.#{adapter}.passenger.conf.erb"
        when 'php'
          "appserver.#{adapter}.php.conf.erb"
        else
          "appserver.#{adapter}.upstream.conf.erb"
        end

        # "appserver.#{adapter}.#{appserver_adapter == 'passenger' ? 'passenger' : 'upstream'}.conf.erb"
      end
    end
  end
end
