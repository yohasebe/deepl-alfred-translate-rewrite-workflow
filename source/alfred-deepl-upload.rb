require './config.rb'
require 'net/http'
require 'uri'
require 'json'

auth_key             = ARGV[0]
source_lang          = ARGV[1]
target_lang          = ARGV[2]
file_path            = ARGV[3]
formality            = ARGV[4]

filename             = File.basename(file_path)
dirname              = File.dirname(file_path)

def parse_result(json)
  res = JSON.parse(json)
  if res && !res.empty?
    return res
  else
    return {"document_id" => nil, "document_key" => nil}
  end
end

def upload_document(query)
  if /\:fx$/ =~ query["auth_key"]
    target_uri = "https://api-free.deepl.com/v2/document"
  else
    target_uri = "https://api.deepl.com/v2/document"
  end

  uri = URI.parse(target_uri)
  req = Net::HTTP::Post.new(uri)

  query_array = query.map{|k, v| [k, v]}
  req.set_form(query_array, "multipart/form-data")
  req_options = {
    use_ssl: uri.scheme == "https"
  }

  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(req)
  end

  result = parse_result(response.body)
  return result
end

res = ""
begin
  f = File.open(file_path, "rb")
  query = {
    "auth_key" => auth_key,
    "file_path" => file_path,
    "source_lang" => source_lang,
    "target_lang" => target_lang,
    "filename" => filename,
    "formality" => formality,
    "file" => f
  }

  res = upload_document(query)
  f.close
  raise res["message"] if !res["document_id"]
rescue => e
  res = "Error: \n" + e.to_s
  print res
  exit
end

res["timestamp"] = Time.now
res["filename"]  = filename
res["dirname"]   = dirname

uploaded_files = {}
data = nil
if File.exist?($DEEPL_DOC_TEMP_FILE)
  File.open($DEEPL_DOC_TEMP_FILE, "r") do |f|
    data = f.read
    uploaded_files = JSON.parse(data)
  end
end

uploaded_files[res["document_id"]] = res
File.open($DEEPL_DOC_TEMP_FILE, "w") do |f|
  f.write uploaded_files.to_json
end

File.open($DEEPL_DOC_LOG_FILE, "a") do |f|
  text  = Time.now.to_s + "\n"
  text += "#{res['document_id']} uploaded\n"
  text += "document_key: #{res['document_key']}\n" 
  query.each do |k, v|
    next if k == "file" || k == "auth_key"
    text += "#{k}: #{v}\n"
  end
  f.write text
end

message  = "File \"#{filename}\" has been uploaded \n"
message += "Document ID:\n#{res['document_id']} \n"
message += "Document KEY:\n#{res['document_key']}\n"

print message
