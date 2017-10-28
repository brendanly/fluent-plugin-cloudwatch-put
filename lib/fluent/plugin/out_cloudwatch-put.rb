require "fluent/plugin/output"
require "aws-sdk"

module Fluent
  module Plugin
    class CloudWatchPutOutput < Fluent::Plugin::Output
      Fluent::Plugin.register_output("cloudwatch", self)

      helpers :inject

      # Credential Configs from fluent-plugin-s3
      # Apache License,  version 2.0
      desc "AWS access key id"
      config_param :aws_key_id, :string, default: nil, secret: true
      desc "AWS secret key."
      config_param :aws_sec_key, :string, default: nil, secret: true
      config_section :assume_role_credentials, multi: false do
        desc "The Amazon Resource Name (ARN) of the role to assume"
        config_param :role_arn, :string, secret: true
        desc "An identifier for the assumed role session"
        config_param :role_session_name, :string
        desc "An IAM policy in JSON format"
        config_param :policy, :string, default: nil
        desc "The duration, in seconds, of the role session (900-3600)"
        config_param :duration_seconds, :integer, default: nil
        desc "A unique identifier that is used by third parties when assuming roles in their customers' accounts."
        config_param :external_id, :string, default: nil, secret: true
      end
      config_section :instance_profile_credentials, multi: false do
        desc "Number of times to retry when retrieving credentials"
        config_param :retries, :integer, default: nil
        desc "IP address (default:169.254.169.254)"
        config_param :ip_address, :string, default: nil
        desc "Port number (default:80)"
        config_param :port, :integer, default: nil
        desc "Number of seconds to wait for the connection to open"
        config_param :http_open_timeout, :float, default: nil
        desc "Number of seconds to wait for one block to be read"
        config_param :http_read_timeout, :float, default: nil
        # config_param :delay, :integer or :proc, :default => nil
        # config_param :http_degub_output, :io, :default => nil
      end
      config_section :shared_credentials, multi: false do
        desc "Path to the shared file. (default: $HOME/.aws/credentials)"
        config_param :path, :string, default: nil
        desc "Profile name. Default to 'default' or ENV['AWS_PROFILE']"
        config_param :profile_name, :string, default: nil
      end

      desc "region name"
      config_param :region, :string, default: ENV["AWS_REGION"] || "us-east-1"

      desc "URI of proxy environment"
      config_param :proxy_uri, :string, default: nil

      desc "CloudWatch metric namespace"
      config_param :namespace, :string
      desc "CloudWatch metric name"
      config_param :metric_name, :string
      desc "CloudWatch metric unit"
      config_param :unit, :string

      config_section :dimensions, multi: true do
        config_param :name, :string
        config_param :key, :string, default: nil
        config_param :value, :string, default: nil
      end

      config_param :value_key, :string
      config_param :storage_resolution, :integer, default: 60
      config_param :use_statistic_sets, :bool, default: false

      config_section :buffer do
        config_set_default :chunk_limit_size, 30 * 1024
      end

      attr_reader :cloudwatch

      def start
        super

        options = setup_credentials
        options[:region] = @region if @region
        options[:http_proxy] = @proxy_uri if @proxy_uri
        log.on_trace do
          options[:http_wire_trace] = true
          options[:logger] = log
        end

        @cloudwatch = Aws::CloudWatch::Client.new(options)
      end

      def write(chunk)
        if @use_statistic_sets
          metric_data = build_statistic_metric_data(chunk)
        else
          metric_data = build_metric_data(chunk)
        end

        @cloudwatch.put_metric_data({
          namespace: @namespace,
          metric_data: metric_data,
        })
      end

      private

      def base_metric_data
        {
          metric_name: @metric_name,
          unit: @unit,
          storage_resolution: @storage_resolution,
        }
      end

      def build_metric_data(chunk)
        metric_data = []
        chunk.msgpack_each do |(timestamp, record)|
          metric_data << base_metric_data.merge({
            dimensions: @dimensions.map { |d|
              {
                name: d.name,
                value: record[d.key],
              }
            },
            value: record[@value_key].to_f,
            timestamp: Time.at(timestamp)
          })
        end
        metric_data
      end

      def build_statistic_metric_data(chunk)
        values = []
        timestamps = []
        chunk.msgpack_each do |(timestamp, record)|
          values << record[@value_key].to_f
          timestamps << timestamp
        end

        [
          base_metric_data.merge({
            dimensions: @dimensions.map { |d|
              {
                name: d.name,
                value: d.value,
              }
            },
            statistic_values: {
              sample_count: values.size,
              sum: values.inject(&:+),
              minimum: values.min,
              maximum: values.max,
            },
            timestamp: Time.at(timestamps.max)
          })
        ]
      end

      # Credential Configs from fluent-plugin-s3
      # Apache License,  version 2.0
      def setup_credentials
        options = {}
        credentials_options = {}
        case
        when @aws_key_id && @aws_sec_key
          options[:access_key_id] = @aws_key_id
          options[:secret_access_key] = @aws_sec_key
        when @assume_role_credentials
          c = @assume_role_credentials
          credentials_options[:role_arn] = c.role_arn
          credentials_options[:role_session_name] = c.role_session_name
          credentials_options[:policy] = c.policy if c.policy
          credentials_options[:duration_seconds] = c.duration_seconds if c.duration_seconds
          credentials_options[:external_id] = c.external_id if c.external_id
          if @region
            credentials_options[:client] = Aws::STS::Client.new(region: @region)
          end
          options[:credentials] = Aws::AssumeRoleCredentials.new(credentials_options)
        when @instance_profile_credentials
          c = @instance_profile_credentials
          credentials_options[:retries] = c.retries if c.retries
          credentials_options[:ip_address] = c.ip_address if c.ip_address
          credentials_options[:port] = c.port if c.port
          credentials_options[:http_open_timeout] = c.http_open_timeout if c.http_open_timeout
          credentials_options[:http_read_timeout] = c.http_read_timeout if c.http_read_timeout
          if ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
            options[:credentials] = Aws::ECSCredentials.new(credentials_options)
          else
            options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
          end
        when @shared_credentials
          c = @shared_credentials
          credentials_options[:path] = c.path if c.path
          credentials_options[:profile_name] = c.profile_name if c.profile_name
          options[:credentials] = Aws::SharedCredentials.new(credentials_options)
        when @aws_iam_retries
          log.warn("'aws_iam_retries' parameter is deprecated. Use 'instance_profile_credentials' instead")
          credentials_options[:retries] = @aws_iam_retries
          if ENV["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"]
            options[:credentials] = Aws::ECSCredentials.new(credentials_options)
          else
            options[:credentials] = Aws::InstanceProfileCredentials.new(credentials_options)
          end
        else
          # Use default credentials
          # See http://docs.aws.amazon.com/sdkforruby/api/Aws/S3/Client.html
        end
        options
      end
    end
  end
end
