require './config.rb'
require 'net/http'
require 'uri'
require 'json'

auth_key = ARGV[0]

if !File.exist?($DEEPL_DOC_TEMP_FILE)
  uploaded_files = []
  items = ["title": "No files uploaded"]
else
  datafile = File.open($DEEPL_DOC_TEMP_FILE, "r")
  data = datafile.read
  datafile.close

  uploaded_files = JSON.parse(data)
  items = []
  uploaded_files.sort_by{ |k, v| -v["timestamp"] }.each do |k, v|
    items << { "title": v["filename"],
               "subtitle": v["timestamp"],
               "arg": [v["document_id"], v["document_key"]]
    }
  end
  items = ["title": "No files uploaded"] if items.empty?
end

res_json = {"items" => items}.to_json

print res_json

