# frozen_string_literal: true

module PlaneTools
  # Mirror GH-hosted images into Plane work-item attachments.
  module Attachments
    MIME_EXT_BY_CTYPE = {
      "image/png" => ".png", "image/jpeg" => ".jpg", "image/gif" => ".gif",
      "image/webp" => ".webp", "image/svg+xml" => ".svg"
    }.freeze

    module_function

    # Two-step download of a GH-hosted image: github.com (with auth)
    # returns a 302 to S3, which we then GET without auth (the presigned
    # URL has its own signature in the query string). NEVER let the auth
    # header forward across the redirect, and NEVER let an upstream error
    # response body land anywhere we'd subsequently log or read - some
    # servers (S3) echo request headers verbatim in error bodies.
    def download_gh_image(gh_dl, plain_dl, url)
      resp = gh_dl.get(url)
      return nil unless [301, 302, 303, 307, 308].include?(resp.status)

      s3_url = resp.headers["location"]
      return nil unless s3_url

      resp = plain_dl.get(s3_url)
      return nil unless resp.status == 200

      { bytes: resp.body, ctype: resp.headers["content-type"] || "application/octet-stream" }
    end

    # Upload bytes to Plane as a work-item attachment (3-step S3 flow).
    # Returns the asset_url (path only, e.g. "/api/assets/v2/.../") which
    # must be prefixed with the Plane base URL when used as <img src>.
    def upload_attachment(plane, project_id, work_item_id, bytes:, ctype:, filename:, gh_url:) # rubocop:disable Metrics/ParameterLists
      slug = plane.slug
      conn = plane.conn

      resp = conn.post(
        "/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/attachments/"
      ) do |r|
        r.body = {
          name: filename, type: ctype, size: bytes.bytesize,
          external_id: gh_url, external_source: "GITHUB"
        }
      end
      raise "attachment creds POST -> #{resp.status}" unless resp.status == 200

      cred = resp.body
      upload = cred["upload_data"]
      asset_id = cred["asset_id"]
      asset_url = cred["asset_url"]

      s3_post(upload, bytes, filename, ctype)

      resp = conn.patch(
        "/api/v1/workspaces/#{slug}/projects/#{project_id}/work-items/#{work_item_id}/attachments/#{asset_id}/"
      ) { |r| r.body = { is_uploaded: true } }
      raise "attachment PATCH -> #{resp.status}" unless [200, 204].include?(resp.status)

      asset_url
    end

    def mirror_one_image(plane, gh, project_id, work_item_id, gh_url, log:, apply:) # rubocop:disable Metrics/ParameterLists
      unless apply
        log.info "      DRY-RUN would mirror image #{gh_url}"
        return nil
      end

      img = download_gh_image(gh.auth_dl, gh.plain_dl, gh_url)
      unless img
        log.warn "      failed to download GH image #{gh_url}"
        return nil
      end

      filename = build_filename(gh_url, img[:ctype])
      asset_url = upload_attachment(
        plane, project_id, work_item_id,
        bytes: img[:bytes], ctype: img[:ctype], filename: filename, gh_url: gh_url
      )
      log.info "      mirrored image -> #{asset_url}"
      asset_url
    end

    def build_filename(gh_url, ctype)
      filename = File.basename(URI(gh_url).path)
      filename = "image" if filename.empty?
      ext = MIME_EXT_BY_CTYPE[ctype.split(";").first.strip.downcase] || ""
      filename = "#{filename}#{ext}" unless filename.include?(".")
      filename
    end

    # multipart/form-data POST to S3 with the presigned fields
    def s3_post(upload, bytes, filename, ctype)
      boundary = SecureRandom.hex(16)
      parts = []
      upload["fields"].each do |k, v|
        parts << "--#{boundary}"
        parts << %(Content-Disposition: form-data; name="#{k}"\r\n)
        parts << v.to_s
      end
      parts << "--#{boundary}"
      parts << %(Content-Disposition: form-data; name="file"; filename="#{filename}"\r\nContent-Type: #{ctype}\r\n)
      parts << bytes
      parts << "--#{boundary}--"
      body = parts.join("\r\n")

      s3 = Faraday.new { |f| f.headers["User-Agent"] = "plane-tools" }
      resp = s3.post(upload["url"]) do |r|
        r.headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        r.body = body
      end
      raise "S3 upload -> #{resp.status}" unless [200, 201, 204].include?(resp.status)
    end
  end
end
