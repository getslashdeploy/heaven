module Heaven
  # Top-level module for Providers.
  module Provider
    # The Amazon elastic beanstalk provider.
    # Example: https://docs.amazonaws.cn/en_us/sdk-for-ruby/v3/developer-guide/eb-example-update-ruby-on-rails-app.html
    class ElasticBeanstalk < DefaultProvider
      def initialize(guid, payload)
        super
        @name = "elastic_beanstalk"
      end

      def archive_name
        "heaven-#{sha}.zip"
      end

      def archive_link
        @archive_link ||= api.archive_link(name_with_owner, :ref => sha)
      end

      def archive_zip
        archive_link.gsub(/legacy\.tar\.gz/, "legacy.zip")
      end

      def archive_path
        @archive_path ||= "#{working_directory}/#{archive_name}"
      end

      def fetch_source_code
        execute_and_log(["curl", archive_zip, "-o", archive_path])
      end

      def execute
        return execute_and_log(["/usr/bin/true"]) if Rails.env.test?

        log_stdout "Beanstalk: Configuring S3 bucket: #{bucket_name}\n"
        configure_s3_bucket
        log_stdout "Beanstalk: Fetching source code from GitHub\n"
        fetch_source_code
        log_stdout "Beanstalk: Uploading source code: #{archive_path} => #{bucket_key}\n"
        upload_source_code
        log_stdout "Beanstalk: Creating application: #{app_name}\n"
        app_version = create_app_version
        log_stdout "Beanstalk: Updating application environment: #{environment_name}\n"
        app_update  = update_app(app_version)
        status.output =  "#{base_url}?region=#{custom_aws_region}#/environment"
        status.output << "/dashboard?applicationName=#{app_name}&environmentId"
        status.output << "=#{app_update[:environment_id]}"
      end

      def base_url
        "https://console.aws.amazon.com/elasticbeanstalk/home"
      end

      def notify
        update_output

        status.success!
      end

      def upload_source_code
        obj = s3.buckets[bucket_name].objects[bucket_key]
        obj.write(Pathname.new(archive_path))
        obj
      end

      private

      def app_version
        @app_version ||= begin
          app_versions = eb.describe_application_versions({ application_name: app_name })
          app_versions.application_versions[0]
        end
      end

      def bucket_name
        app_version.source_bundle.s3_bucket
      end

      def bucket_key
        [app_name, archive_name].join("/")
      end

      def app_name
        custom_payload_config && custom_payload_config["app_name"]
      end

      def environment_name
        "#{app_name}-#{environment}"
      end

      def configure_s3_bucket
        return if s3.buckets.map(&:name).include?(bucket_name)
        eb.create_storage_location
      end

      def create_app_version
        options = {
          :application_name  => app_name,
          :version_label     => version_label,
          :description       => description,
          :source_bundle     => {
            :s3_key          => bucket_key,
            :s3_bucket       => bucket_name
          },
          :auto_create_application => false
        }
        eb.create_application_version(options)
      end

      def update_app(version)
        options = {
          :environment_name  => environment_name,
          :version_label     => version[:application_version][:version_label]
        }
        eb.update_environment(options)
      end

      def version_label
        "heaven-#{sha}-#{Time.now.to_i}"
      end

      def custom_aws_region
        (custom_payload &&
         custom_payload["aws"] &&
          custom_payload["aws"]["region"]) || "us-east-1"
      end

      def aws_config
        {
          "region"            => custom_aws_region,
          "logger"            => Logger.new(stdout_file),
          "access_key_id"     => ENV["BEANSTALK_ACCESS_KEY_ID"],
          "secret_access_key" => ENV["BEANSTALK_SECRET_ACCESS_KEY"]
        }
      end

      def s3
        @s3 ||= AWS::S3.new(aws_config)
      end

      def eb
        @eb ||= AWS::ElasticBeanstalk::Client.new(aws_config)
      end
    end
  end
end
