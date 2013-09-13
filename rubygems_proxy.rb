require "open-uri"
require "open_uri_redirections"
require "net/http"
require "fileutils"
require "logger"
require "erb"

class RubygemsProxy
  RUBY_GEMS_BASE_URI = "http://rubygems.org"

  attr_reader :env

  def self.call(env)
    new(env).run
  end

  def initialize(env)
    @env = env
    logger.level = Logger::INFO
  end

  def run
    http_method = env["REQUEST_METHOD"]
    logger.info "#{http_method} #{env["PATH_INFO"]}"

    return update_specs if http_method == "DELETE"

    return handle_head_request if http_method == 'HEAD'

    case env["PATH_INFO"]
      when "/"
        [200, {"Content-Type" => "text/html"}, [erb(:index)]]
      else
        [200, {"Content-Type" => "application/octet-stream"}, [contents]]
    end
  rescue Exception
    [200, {"Content-Type" => "text/html"}, [erb(404)]]
  end

  private
  def erb(view)
    ERB.new(template(view)).result(binding)
  end

  def server_url
    env["rack.url_scheme"] + "://" + File.join(env["SERVER_NAME"], env["PATH_INFO"])
  end

  def rubygems_url(gemname)
    "http://rubygems.org/gems/%s" % Rack::Utils.escape(gemname)
  end

  def gem_url(name, version)
    File.join(server_url, "gems", Rack::Utils.escape("#{name}-#{version}.gem"))
  end

  def gem_list
    Dir[File.dirname(__FILE__) + "/public/gems/**/*.gem"]
  end

  def grouped_gems
    gem_list.inject({}) do |buffer, file|
      basename = File.basename(file)
      parts = basename.gsub(/\.gem/, "").split("-")
      version = parts.pop
      name = parts.join("-")

      buffer[name] ||= []
      buffer[name] << version
      buffer
    end
  end

  def template(name)
    @templates ||= {}
    @templates[name] ||= File.read(File.dirname(__FILE__) + "/views/#{name}.erb")
  end

  def root_dir
    File.expand_path "..", __FILE__
  end

  def logger
    @logger ||= Logger.new("#{root_dir}/tmp/server.log", 10, 1024000)
  end

  def cache_dir
    "#{root_dir}/public"
  end

  def handle_head_request
    if cached?
      [200, {'Content-Type' => '', 'Content-Length' => File.size(filepath).to_s}, []]
    else
      req = Net::HTTP.new('www.rubygems.org', 80)
      resp = req.request_head(env["PATH_INFO"])
      headers = Hash[resp.to_hash.map { |k, v| [k, v.join('; ')] }]
      p [resp.code.to_i, headers, resp.body]
      [resp.code.to_i, headers, resp.body || []]
    end
  rescue Exception => ex
    puts ex.inspect
    0
  end

  def contents
    if File.directory?(filepath)
      erb(404)
    elsif cached?
      logger.info "Read from cache: #{filepath}"
      open(filepath).read
    else
      logger.info "Read from interwebz: #{url}"
      open(url, :allow_redirections => :safe).read.tap { |content| save(content) }
    end
  rescue Exception => error
    # Just try to load from file if something goes wrong.
    # This includes HTTP timeout, or something.
    # If it fails again, we won't have any files anyway!
    logger.error "Error: #{error.class} => #{error.message}"
    open(filepath).read
  end

  def save(contents)
    FileUtils.mkdir_p File.dirname(filepath)
    File.open(filepath, "wb") { |handler| handler << contents }
  end

  def cached?
    case File.basename(filepath)
      when /^specs\./
        File.exist?(filepath) && (Time.now - File.mtime(filepath)).to_i < 84600
      when /\.gz$/
        false
      else
        File.file?(filepath)
    end
  end

  def specs?
    env["PATH_INFO"] =~ /specs\..+\.gz$/
  end

  def filepath
    if specs?
      File.join(root_dir, env["PATH_INFO"])
    else
      File.join(cache_dir, env["PATH_INFO"])
    end
  end

  def url
    File.join(RUBY_GEMS_BASE_URI, env["PATH_INFO"])
  end

  def update_specs
    Dir[File.dirname(__FILE__) + "/*.gz"].each { |file| File.unlink(file) }
    [200, {"Content-Type" => "text/plain"}, [""]]
  end
end
