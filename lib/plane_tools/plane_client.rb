# frozen_string_literal: true

module PlaneTools
  # Adaptive rate-limit pacing. Plane returns `X-RateLimit-Remaining`
  # (calls left in the current window) and `X-RateLimit-Reset` (epoch
  # seconds when the bucket refills). When remaining drops below the
  # safety threshold, we sleep until just after reset so we don't hit
  # 429s mid-burst.
  class RateLimitPacer < Faraday::Middleware
    THRESHOLD = 5

    def on_complete(env)
      remaining = env.response_headers["x-ratelimit-remaining"]&.to_i
      reset = env.response_headers["x-ratelimit-reset"]&.to_i
      limit = env.response_headers["x-ratelimit-limit"]&.to_i
      server_date = env.response_headers["date"]
      return unless remaining && reset

      now = Time.now.to_i
      reset_in = reset - now
      reset_at = Time.at(reset).utc.iso8601
      now_at = Time.at(now).utc.iso8601
      server_epoch = server_date ? Time.httpdate(server_date).to_i : nil
      skew = server_epoch ? server_epoch - now : nil
      warn "[rate-limit] #{env.method.to_s.upcase} #{env.url.path} " \
           "limit=#{limit || '?'} remaining=#{remaining} " \
           "reset=#{reset} (#{reset_at}, in #{reset_in}s) " \
           "now=#{now} (#{now_at}) " \
           "server_date=#{server_date.inspect} skew=#{skew.inspect}s"

      return unless remaining < THRESHOLD

      sleep_for = reset_in + 1
      return if sleep_for <= 0

      warn "[rate-limit] remaining=#{remaining} < #{THRESHOLD}, " \
           "sleeping #{sleep_for}s (reset_in=#{reset_in}s + 1s pad) " \
           "until #{Time.at(now + sleep_for).utc.iso8601}"
      sleep(sleep_for)
      warn "[rate-limit] woke at #{Time.now.utc.iso8601}"
    end
  end

  # Faraday wrapper for the Plane REST API, plus the high-level
  # endpoints we hit. All endpoint helpers assume the workspace
  # slug is fixed for the life of the client.
  class PlaneClient
    attr_reader :slug, :base_url, :conn

    def initialize(token:, slug:, base_url:)
      @slug = slug
      @base_url = base_url
      @conn = Faraday.new(url: base_url) do |f|
        # Default `methods` only includes idempotent verbs (GET, HEAD, etc.).
        # Our POST/PATCH calls ARE idempotent (matched by external_id), so
        # tell Faraday to retry them too. Plane returns HTTP 429 on rate
        # limits; faraday-retry honors Retry-After automatically and acts as
        # a safety net under the proactive pacer below.
        f.request :retry, max: 6, interval: 0.5, backoff_factor: 2,
                          retry_statuses: [429, 502, 503, 504],
                          methods: %i[get head post patch delete]
        f.use RateLimitPacer
        f.request :json
        f.response :json, content_type: /\bjson$/
        f.headers["X-API-Key"] = token
        f.headers["Accept"] = "application/json"
      end
    end

    # Walks Plane's cursor-paginated list endpoints.
    def paged(path, params = {})
      results = []
      cursor = nil
      loop do
        p = params.merge(per_page: 100)
        p[:cursor] = cursor if cursor
        resp = @conn.get(path, p)
        raise "GET #{path} -> #{resp.status}: #{resp.body.inspect[0, 300]}" unless resp.success?

        body = resp.body
        rows = body.is_a?(Hash) ? (body["results"] || []) : Array(body)
        results.concat(rows)
        cursor = body.is_a?(Hash) ? body["next_cursor"] : nil
        break if cursor.nil? || cursor.to_s.empty? || rows.empty?
        # Defensive: some Plane endpoints echo same cursor when no more pages.
        break if body.is_a?(Hash) && body["next_cursor"] == body["prev_cursor"]
      end
      results
    end

    def me
      resp = @conn.get("/api/v1/users/me/")
      raise "GET /users/me/ -> #{resp.status}" unless resp.status == 200

      resp.body
    end

    def projects
      paged("/api/v1/workspaces/#{slug}/projects/")
    end

    def github_work_items(project_id)
      paged("/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/",
            external_source: "GITHUB")
    end

    def comments(project_id, work_item_id)
      paged("/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/comments/")
    end

    def post_comment(project_id, work_item_id, payload)
      resp = @conn.post(
        "/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/comments/",
        payload
      )
      raise "POST comment -> #{resp.status}: #{resp.body.inspect[0, 500]}" unless resp.success?

      resp.body
    end

    def patch_comment(project_id, work_item_id, comment_id, payload)
      resp = @conn.patch(
        "/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/comments/#{comment_id}/",
        payload
      )
      raise "PATCH comment -> #{resp.status}: #{resp.body.inspect[0, 500]}" unless resp.success?

      resp.body
    end

    def attachments(project_id, work_item_id)
      paged("/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/attachments/")
    end
  end
end
