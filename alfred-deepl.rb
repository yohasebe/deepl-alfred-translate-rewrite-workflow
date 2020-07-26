require 'net/http'
require 'uri'
require 'json'

auth_key = ARGV[0]
primary_lang = ARGV[1]
secondary_lang = ARGV[2]

# Conversion Mode
# "translate": Lang1 to Lang2
# "rewrite": Lang1 to Lang2 then lang 1 back again
mode = ARGV[3] || "translate"

# Show Original Text
# "true"
# "false"
show_original_text = ARGV[4] || "false"
show_original_text = show_original_text == "true" ? true : false

max_characters = ARGV[5] || 1000 

# Split Mode
# "0": no split
# "1": splits on interpunction and newlines
# "nonewlines": splits on interpunction only
split_sentences = ARGV[6] || "1"

# Preserve Fromatting
# "0": default
# "1": respects original formatting
preserve_formatting = ARGV[7] || "0"

# Formality (only available in limited languages)
# "default"
# "more"
# "less"
formality = ARGV[8] || "default"

original_text = `pbpaste | textutil -convert txt -stdin -stdout`.strip

if original_text.length > max_characters.to_i
  print "❗️ ERROR: Input text contains #{original_text.length} characters; max number of characters is set to #{max_characters}"
  exit
elsif /\A\s*\z/ =~ original_text
  print "❗️ ERROR: Input text is empty"
end

def parse(json)
  begin
    res = JSON.parse(json)
    if trans = res["translations"]
      return trans.first
    else
      return {"text" => nil, "detected_source_language" => nil}
    end
  rescue => e
    return {"text" => nil, "detected_source_language" => nil}
  end
end

def translate(query)
  target_uri = "https://api.deepl.com/v2/translate"

  uri = URI.parse(target_uri)
  req = Net::HTTP::Post.new(uri)

  req.set_form_data(query)
  req_options = {
    use_ssl: uri.scheme == "https" 
  }

  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(req)
  end

  return parse response.body
end

intermediate = ""
results = ""
begin
  source = secondary_lang
  target = primary_lang

  query = {
    "auth_key" => auth_key,
    "text" => original_text,
    "target_lang" => target,
    "split_sentences" => split_sentences,
    "preserve_formatting" => preserve_formatting, 
    # "formality" => formality
  }

  res = translate(query)
  if res["detected_source_language"] != source 
    source = primary_lang
    target = secondary_lang
    query["source_lang"] = source
    query["target_lang"] = target
    res = translate(query)
  end

  case mode
  when "translate"
    results << original_text + "\n\n" if show_original_text
    results << res["text"]
  when "rewrite"
    intermediate = res["text"]
    reversed_source = target
    reversed_target = source 
    query["text"] = intermediate
    query["source_lang"] = reversed_source
    query["target_lang"] = reversed_target
    new_res = translate(query)
    results << original_text + "\n\n" if show_original_text
    results << intermediate + "\n\n" + new_res["text"]
  end
rescue => e
  results = "❗️ ERROR: " + e.to_s
end

print results
