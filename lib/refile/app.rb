require "json"
require "rack"
require "tempfile"
require "digest/sha1"

module Refile
  # A Rack application which can be mounted or run on its own.
  #
  # @example mounted in Rails
  #   Rails.application.routes.draw do
  #     mount Refile::App.new, at: "attachments", as: :refile_app
  #   end
  #
  # @example as standalone app
  #   require "refile"
  #
  #   run Refile::App.new
  class App
    class Acts
      def initialize
        @acts = []
      end

      def <<(act)
        @acts << act
      end

      def match(path)
        @acts.find { |act| act.match path }
      end
    end

    class Act
      attr_reader :params, :block

      def initialize(pattern, block)
        @pattern = route(pattern)
        @block = block
        @params = nil
      end

      def match(str)
        @pattern.match(str).tap do |matched|
          if matched
            @params = matched.names.map { |name| [name.to_sym, matched[name]] }.to_h
            @params[:splat] = Array(@params[:splat]) if @params.key? :splat
          end
        end
      end

      FIXES = { "." => "\\.", "*" => "(?<splat>.*?)" }.freeze

      def route(pattern)
        %r{\A#{pattern.gsub(Regexp.union(*FIXES.keys), FIXES).gsub(%r{(/?):(\w+)}) { "#{$1}(?<#{$2}>[^/]+)" }}\z}
      end
    end

    module DSL
      def get(pattern, &block)
        act = Act.new(pattern, block)
        actions["GET"] << act
        actions["HEAD"] << act
      end

      def post(pattern, &block)
        actions["POST"] << Act.new(pattern, block)
      end

      def options(pattern, &block)
        actions["OPTIONS"] << Act.new(pattern, block)
      end

      def actions
        @actions ||= Hash.new { |hash, key| hash[key] = Acts.new }
      end
    end
    extend DSL

    get "/:token/:backend/:id/:filename" do |params|
      @params = params
      forbidden unless verified?
      set_cors_headers
      stream_file file
    end

    get "/:backend/presign" do |params|
      @params = params
      not_found unless upload_allowed?
      set_cors_headers
      json backend.presign.to_json
    end

    get "/:token/:backend/:processor/*/:id/:file_basename.:extension" do |params|
      @params = params
      forbidden unless verified?
      set_cors_headers
      splat = Array(@params[:splat])
      stream_file processor.call(file, *splat.first.split("/"), format: @params[:extension])
    end

    get "/:token/:backend/:processor/*/:id/:filename" do |params|
      @params = params
      forbidden unless verified?
      set_cors_headers
      splat = Array(@params[:splat])
      stream_file processor.call(file, *splat.first.split("/"))
    end

    get "/:token/:backend/:processor/:id/:file_basename.:extension" do |params|
      @params = params
      forbidden unless verified?
      set_cors_headers
      stream_file processor.call(file, format: @params[:extension])
    end

    get "/:token/:backend/:processor/:id/:filename" do |params|
      @params = params
      forbidden unless verified?
      set_cors_headers
      stream_file processor.call(file)
    end

    post "/:backend" do |params|
      @params = params
      not_found unless upload_allowed?
      tempfile = request.params.fetch("file").fetch(:tempfile)
      filename = request.params.fetch("file").fetch(:filename)
      file = backend.upload(tempfile)
      url = Refile.file_url(file, filename: filename)
      json({ id: file.id, url: url }.to_json)
    end

    options "/:backend" do
      response.body = [""]
      finish response.finish
    end

    NOT_FOUND = [404, { "Content-Type" => "text/plain;charset=utf-8" }, ["not found"]].freeze
    FORBIDDEN = [403, { "Content-Type" => "text/plain;charset=utf-8" }, ["forbidden"]].freeze

    attr_reader :env, :request, :response, :params

    def call(env)
      catch(:finish) do
        dup.process env
      end
    end

    def process(env)
      @env      = env
      @request  = Rack::Request.new env
      @response = Rack::Response.new
      @params   = nil
      dispatch
    end

    def dispatch
      action = self.class.actions[request.request_method].match(path_info)
      if action
        set_cors_headers
        instance_exec(action.params, &action.block)
      else
        not_found
      end
    rescue Refile::InvalidFile => e
      logger.error "Error -> #{e}"
      response.status = 400
      response["Content-Type"] = "text/html;charset=utf-8"
      response.body = ["Upload failure error"]
      finish response.finish
    rescue Refile::InvalidMaxSize => e
      logger.error "Error -> #{e}"
      response.status = 413
      response["Content-Type"] = "text/html;charset=utf-8"
      response.body = ["Upload failure error"]
      finish response.finish
    rescue => e
      logger.error "Error -> #{e}"
      e.backtrace.each do |line|
        logger.error line
      end
      response.status = 400
      response["Content-Type"] = "text/plain;charset=utf-8"
      response.body = ["error"]
      finish response.finish
    end

    def set_cors_headers
      return unless Refile.allow_origin
      response["Access-Control-Allow-Origin"] = Refile.allow_origin
      response["Access-Control-Allow-Headers"] = request.env["HTTP_ACCESS_CONTROL_REQUEST_HEADERS"].to_s
      response["Access-Control-Allow-Method"] = request.env["HTTP_ACCESS_CONTROL_REQUEST_METHOD"].to_s
    end

    def finish(with)
      if request.head?
        throw :finish, [with[0], with[1], []]
      else
        throw :finish, with
      end
    end

    def forbidden
      finish FORBIDDEN
    end

    def not_found
      finish NOT_FOUND
    end

    def json(json)
      response["Content-Type"] = "application/json"
      response.body = [json]
      finish response.finish
    end

    def download_allowed?
      Refile.allow_downloads_from == :all or Refile.allow_downloads_from.include?(params[:backend])
    end

    def upload_allowed?
      Refile.allow_uploads_to == :all or Refile.allow_uploads_to.include?(params[:backend])
    end

    def logger
      Refile.logger
    end

    def stream_file(file)
      expires Refile.content_max_age

      basename = ::File.basename(request.path.split("/").last)
      response["Content-Disposition"] = %(inline; filename="#{basename}")

      extname = ::File.extname(request.path)
      response["Content-Type"] = Rack::Mime.mime_type(extname)

      if file.respond_to?(:path)
        response.body = ::File.open(file.path, "rb")
      else
        tempfile = Tempfile.new(params[:id])
        IO.copy_stream file, tempfile.path
        response.body = tempfile
      end

      finish response.finish
    end

    def expires(amount)
      amount = amount.to_i
      response["Cache-Control"] = "public max-age=#{amount}"
      response["Expires"] = (Time.now + amount).httpdate
    end

    def file
      file = backend.get(params[:id])
      if file.exists?
        file.download
      else
        logger.error "Could not find attachment by id: #{params[:id]}"
        not_found
      end
    end

    def backend
      Refile.backends.fetch(params[:backend]) do |name|
        logger.error "Could not find backend: #{name}"
        not_found
      end
    end

    def processor
      Refile.processors.fetch(params[:processor]) do |name|
        logger.error "Could not find processor: #{name}"
        not_found
      end
    end

    def verified?
      base_path = request.path.gsub(::File.join(request.script_name, params[:token]), "")

      Refile.valid_token?(base_path, params[:token])
    end

    def path_info
      # Rack::Utils.clean_path_info Rack::Utils.unescape_path request.path_info
      request.path_info
    end
  end
end
