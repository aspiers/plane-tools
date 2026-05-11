# frozen_string_literal: true

module PlaneTools
  # Loads .env + the YAML project map.
  #
  # The YAML map is keyed by Plane project identifier (the short
  # prefix shown in work item IDs, e.g. "D4D" for "D4D-42"); each
  # value is the GitHub repo (`owner/name`) the project's work items
  # mirror.
  class Config
    attr_reader :plane_token, :plane_slug, :plane_base,
                :github_token, :project_map, :root

    def self.load(root)
      new(root).tap(&:load!)
    end

    def initialize(root)
      @root = root
    end

    def load!
      load_env!
      load_project_map!
      self
    end

    def project(identifier)
      @project_map[identifier]
    end

    def each_project(&)
      @project_map.each(&)
    end

    private

    def load_env!
      env_path = File.expand_path(".env", @root)
      unless File.exist?(env_path)
        warn "error: #{env_path} not found"
        warn "       copy .env.example to .env and fill in your Plane + GitHub credentials."
        exit 1
      end
      Dotenv.load(env_path)

      @plane_token  = ENV.fetch("PLANE_API_TOKEN")
      @plane_slug   = ENV.fetch("PLANE_WORKSPACE_SLUG")
      @plane_base   = ENV.fetch("PLANE_BASE_URL", "https://api.plane.so")
      @github_token = ENV.fetch("GITHUB_TOKEN") { `gh auth token`.strip }
      raise "no GitHub token (set GITHUB_TOKEN or run gh auth login)" if @github_token.empty?
    end

    def load_project_map!
      map_path = File.expand_path("config/plane_github_map.yml", @root)
      unless File.exist?(map_path)
        warn "error: #{map_path} not found"
        warn "       copy config/plane_github_map.example.yml to config/plane_github_map.yml " \
             "and edit it for your projects."
        exit 1
      end
      raw = YAML.load_file(map_path)
      raise "config/plane_github_map.yml must be a Hash, got #{raw.class}" unless raw.is_a?(Hash)

      @project_map = raw.each_with_object({}) do |(ident, value), h|
        raise "project #{ident}: value must be a repo string, got #{value.class}" unless value.is_a?(String)

        h[ident] = { repo: value }
      end
    end
  end
end
