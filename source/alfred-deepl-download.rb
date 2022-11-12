require './config.rb'
require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

auth_key     = ARGV[0]
document_id  = ARGV[1]
document_key = ARGV[2]

def download(auth_key, doc_id, doc_key)
  query = {
    "auth_key" => auth_key,
    "document_id" => doc_id,
    "document_key" => doc_key
  }

  if /\:fx$/ =~ query["auth_key"]
    target_uri = "https://api-free.deepl.com/v2/document/#{doc_id}/result"
  else
    target_uri = "https://api.deepl.com/v2/document/#{doc_id}/result"
  end

  uri = URI.parse(target_uri)
  req = Net::HTTP::Post.new(uri)

  req.set_form_data(query)
  req_options = {
    use_ssl: uri.scheme == "https"
  }

  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(req)
  end

  return response.body
end

def check_status(auth_key, doc_id, doc_key)
  query = {
    "auth_key" => auth_key,
    "document_id" => doc_id,
    "document_key" => doc_key
  }

  if /\:fx$/ =~ query["auth_key"]
    target_uri = "https://api-free.deepl.com/v2/document/#{doc_id}"
  else
    target_uri = "https://api.deepl.com/v2/document/#{doc_id}"
  end

  uri = URI.parse(target_uri)
  req = Net::HTTP::Post.new(uri)

  req.set_form_data(query)
  req_options = {
    use_ssl: uri.scheme == "https"
  }

  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(req)
  end

  return JSON.parse response.body
end

uploaded_files = {}
data = nil
if File.exist?($DEEPL_DOC_TEMP_FILE)
  File.open($DEEPL_DOC_TEMP_FILE, "r") do |f|
    data = f.read
    uploaded_files = JSON.parse(data)
  end
end

filename = uploaded_files[document_id]["filename"]
basename = File.basename(filename, ".*")
extname = File.extname(filename)
dirname  = uploaded_files[document_id]["dirname"]
unless File.directory?(dirname)
  FileUtils.mkdir_p(dirname)
end

current_status = check_status(auth_key, document_id, document_key)

message = ""
if current_status["status"] == "done"
  begin
    blob = download(auth_key, document_id, document_key)
    filepath = File.join(dirname, "#{basename}-#{document_id}#{extname}")
    File.open(filepath, "wb") do |f|
      f.write blob
    end

    uploaded_files.delete(document_id)

    File.open($DEEPL_DOC_TEMP_FILE, "w") do |f|
      f.write uploaded_files.to_json
    end

    File.open($DEEPL_DOC_LOG_FILE, "a") do |f|
      f.write Time.now.to_s + "\n#{document_id} downloaded\n"
    end

    message = "Filepath:#{filepath}"
  rescue
    message = "Error: Something went wrong"
  end
else
  message  = "Please check again later.\n"
  message += "Current status: #{current_status['status']}\n"
  # message += "Seconds remaining: #{current_status['seconds_remaining']}"
end

print message

