# frozen_string_literal: true

require 'json'
require 'yaml'

require 'qeweney'
require 'papercraft'

require 'syntropy/errors'
require 'syntropy/file_watch'
require 'syntropy/module'

module Syntropy
  class App
    attr_reader :route_cache

    def initialize(machine, src_path, mount_path, opts = {})
      @machine = machine
      @src_path = File.expand_path(src_path)
      @mount_path = mount_path
      @route_cache = {}
      @opts = opts

      @relative_path_re = calculate_relative_path_re(mount_path)
      @machine.spin do
        # we do startup stuff asynchronously, in order to first let TP2 do its
        # setup tasks
        @machine.sleep 0.15
        @opts[:logger]&.call("Serving from #{File.expand_path(@src_path)}")
        start_file_watcher if opts[:watch_files]
      end

      @module_loader ||= Syntropy::ModuleLoader.new(@src_path, @opts)
    end

    def find_route(path, cache: true)
      cached = @route_cache[path]
      return cached if cached

      entry = calculate_route(path)
      @route_cache[path] = entry if entry[:kind] != :not_found && cache
      entry
    end

    def call(req)
      entry = find_route(req.path)
      render_entry(req, entry)
    rescue StandardError => e
      p e
      p e.backtrace
      req.respond(e.message, ':status' => Qeweney::Status::INTERNAL_SERVER_ERROR)
    end

    private

    def start_file_watcher
      @opts[:logger]&.call('Watching for module file changes...', nil)
      wf = @opts[:watch_files]
      period = wf.is_a?(Numeric) ? wf : 0.1
      @machine.spin do
        Syntropy.file_watch(@machine, @src_path, period: period) do
          @opts[:logger]&.call("Detected changed file: #{it}")
          invalidate_cache(it)
        rescue Exception => e
          p e
          p e.backtrace
          exit!
        end
      end
    end

    def invalidate_cache(fn)
      @module_loader.unload(fn)

      invalidated_keys = []
      @route_cache.each do |k, v|
        @opts[:logger]&.call("Invalidate cache for #{k}", nil)
        invalidated_keys << k if v[:fn] == fn
      end

      invalidated_keys.each { @route_cache.delete(it) }
    end

    def calculate_relative_path_re(mount_path)
      mount_path = '' if mount_path == '/'
      %r{^#{mount_path}(?:/(.*))?$}
    end

    FILE_KINDS = {
      '.rb' => :module,
      '.md' => :markdown
    }
    NOT_FOUND = { kind: :not_found }

    # We don't allow access to path with /.., or entries that start with _
    FORBIDDEN_RE = %r{(/_)|((/\.\.)/?)}

    def calculate_route(path)
      return NOT_FOUND if path =~ FORBIDDEN_RE

      m = path.match(@relative_path_re)
      return NOT_FOUND if !m

      relative_path = m[1] || ''
      fs_path = File.join(@src_path, relative_path)

      return file_entry(fs_path) if File.file?(fs_path)
      return find_index_entry(fs_path) if File.directory?(fs_path)

      entry = find_file_entry_with_extension(fs_path)
      return entry if entry[:kind] != :not_found

      find_up_tree_module(path)
    end

    def file_entry(fn)
      { fn: File.expand_path(fn), kind: FILE_KINDS[File.extname(fn)] || :static }
    end

    def find_index_entry(dir)
      find_file_entry_with_extension(File.join(dir, 'index'))
    end

    def find_file_entry_with_extension(path)
      fn = "#{path}.html"
      return file_entry(fn) if File.file?(fn)

      fn = "#{path}.md"
      return file_entry(fn) if File.file?(fn)

      fn = "#{path}.rb"
      return file_entry(fn) if File.file?(fn)

      fn = "#{path}+.rb"
      return file_entry(fn) if File.file?(fn)

      NOT_FOUND
    end

    def find_up_tree_module(path)
      parent = parent_path(path)
      return NOT_FOUND if !parent

      entry = find_route("#{parent}+.rb", cache: false)
      entry[:kind] == :module ? entry : NOT_FOUND
    end

    UP_TREE_PATH_RE = %r{^(.+)?/[^/]+$}

    def parent_path(path)
      m = path.match(UP_TREE_PATH_RE)
      m && m[1]
    end

    def render_entry(req, entry)
      case entry[:kind]
      when :not_found
        req.respond('Not found', ':status' => Qeweney::Status::NOT_FOUND)
      when :static
        respond_static(req, entry)
      when :markdown
        body = render_markdown(entry[:fn])
        req.respond(body, 'Content-Type' => 'text/html')
      when :module
        call_module(req, entry)
      else
        raise 'Invalid entry kind'
      end
    end

    def respond_static(req, entry)
      entry[:mime_type] ||= Qeweney::MimeTypes[File.extname(entry[:fn])]
      req.respond(IO.read(entry[:fn]), 'Content-Type' => entry[:mime_type])
    end

    def call_module(req, entry)
      entry[:code] ||= load_module(entry)
      if entry[:code] == :invalid
        req.respond(nil, ':status' => Qeweney::Status::INTERNAL_SERVER_ERROR)
        return
      end

      entry[:code].call(req)
    rescue StandardError => e
      p e
      p e.backtrace
      req.respond(nil, ':status' => Qeweney::Status::INTERNAL_SERVER_ERROR)
    end

    def load_module(entry)
      ref = entry[:fn].gsub(%r{^#{@src_path}/}, '').gsub(/\.rb$/, '')
      o = @module_loader.load(ref)
      o.is_a?(Papercraft::Template) ? wrap_template(o) : o
    rescue Exception => e
      @opts[:logger]&.call("Error while loading module #{ref}: #{e.message}")
      :invalid
    end

    def wrap_template(templ)
      lambda { |req|
        body = templ.render
        req.respond(body, 'Content-Type' => 'text/html')
      }
    end

    def render_markdown(fn)
      atts, md = parse_markdown_file(fn)

      if atts[:layout]
        layout = @module_loader.load("_layout/#{atts[:layout]}")
        html = layout.apply { emit_markdown(md) }.render
      else
        html = Papercraft.markdown(md)
      end
      html
    end

    DATE_REGEXP = /(\d{4}\-\d{2}\-\d{2})/
    FRONT_MATTER_REGEXP = /\A(---\s*\n.*?\n?)^((---|\.\.\.)\s*$\n?)/m
    YAML_OPTS = {
      permitted_classes: [Date],
      symbolize_names: true
    }

    # Parses the markdown file at the given path.
    #
    # @param path [String] file path
    # @return [Array] an tuple containing properties<Hash>, contents<String>
    def parse_markdown_file(path)
      content = IO.read(path) || ''
      atts = {}

      # Parse date from file name
      if (m = path.match(DATE_REGEXP))
        atts[:date] ||= Date.parse(m[1])
      end

      if (m = content.match(FRONT_MATTER_REGEXP))
        front_matter = m[1]
        content = m.post_match

        yaml = YAML.safe_load(front_matter, **YAML_OPTS)
        atts = atts.merge(yaml)
      end

      [atts, content]
    end
  end
end
