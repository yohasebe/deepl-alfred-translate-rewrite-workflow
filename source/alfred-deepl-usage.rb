require './config.rb'
require 'net/http'
require 'uri'
require 'json'

auth_key = ARGV[0]

def parse_usage(json)
  res = JSON.parse(json)
  if res && !res.empty?
    return res 
  else
    return {"character_count" => nil, "character_limit" => nil}
  end
end

def monitor_usage(query)
  if /\:fx$/ =~ query["auth_key"]
    target_uri = "https://api-free.deepl.com/v2/usage"
  else
    target_uri = "https://api.deepl.com/v2/usage"
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

  return parse_usage response.body
end

def delimit_digits(s)
  s.to_s.reverse.gsub( /(\d{3})(?=\d)/, '\1,').reverse
end

results = ""
begin
  query = {
    "auth_key" => auth_key,
  }
  res = monitor_usage(query)
  character_count = res["character_count"]
  character_limit = res["character_limit"]
  ratio = character_count.to_f / character_limit.to_f * 100 
  results << delimit_digits(character_count) + " chars translated so far in the billing period.\n\n"
  results << ratio.floor(2).to_s + "% of the char limit (#{delimit_digits(character_limit)}) has been used."
rescue => e
  results = "Error: \n" + e.to_s
end

print results
