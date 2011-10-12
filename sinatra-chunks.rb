require 'sinatra'
require 'raw_recognizer'
require 'uuidtools'
require 'json'
require 'iconv'
require 'set'
require 'yaml'
require 'open-uri'
require 'md5'
require 'uri'

configure do
  $config = {}
  $config = YAML.load_file('conf.yaml')
  RECOGNIZER = Recognizer.new($config, 'pocketsphinx.ngram')
  FSG_RECOGNIZER = Recognizer.new($config, 'pocketsphinx.fsg')
  
  $prettifier = nil
  if $config['prettifier'] != nil
    $prettifier = IO.popen($config['prettifier'], mode="r+")
  end
  disable :show_exceptions
  
  $outdir = nil
  begin
    $outdir = $config.fetch('logging', {}).fetch('request-debug', '')
  rescue
  end
  
  
  CHUNK_SIZE = 4*1024
end

post '/recognize' do
  do_post()
end

put '/recognize' do
  do_post()
end

put '/recognize/*' do
  do_post()
end


def do_post()
  id = SecureRandom.hex
  puts "Request ID: " + id
  req = Rack::Request.new(env)
  
  puts headers
  
  lm_name = req.params['lm']
  puts "Client requests to use lm=#{lm_name}"
  
  output_lang = ""
  pgf_dir = ""
  pgf_basename = ""
  input_lang = ""
  
  if lm_name != nil and lm_name != ""  
    lm_type = req.params['lm-type']
    puts "Using FSG recognizer"  
    @use_rec = FSG_RECOGNIZER
		if lm_name =~ /jsgf$/
		  puts "Using JSGF-based grammar"
			dict_file = dict_file_from_url(lm_name)
			fsg_file = fsg_file_from_url(lm_name)
			if not File.exists? fsg_file
				raise IOError, "Language model #{lm_name} not available. Use /fetch-jsgf API call to upload it to the server"
			end
			if not File.exists? dict_file
				raise IOError, "Pronunciation dictionary for #{lm_name} not available. Use /fetch-jsgf API call to make it on the server"
			end
			@use_rec.set_fsg(fsg_file, dict_file)      
		elsif lm_name =~ /pgf$/
		  puts "Using GF-based grammar"
		  input_lang = req.params['input-lang']
		  if input_lang == nil
		    input_lang = $config.fetch('gf', {}).fetch('default_input_lang', 'Est')
		  end
		  output_lang = req.params['output-lang']
			digest = MD5.hexdigest lm_name
      pgf_dir = $config.fetch('gf', {}).fetch('grammar-dir', 'user_gfs') + '/' + digest
      pgf_basename = File.basename(URI.parse(lm_name).path, ".pgf")
  	  fsg_file = pgf_dir + '/' + pgf_basename + input_lang + ".fsg"
	    dict_file = pgf_dir + '/' + pgf_basename + input_lang + ".dict"
			if not File.exists? fsg_file
				raise IOError, "Grammar for lang #{lang} for #{lm_name} not available. Use /fetch-pgf API call to upload it to the server"
			end
			if not File.exists? dict_file
				raise IOError, "Pronunciation dictionary  for lang #{lang} for #{lm_name} not available. Use /fetch-pgf API call to make it on the server"
			end
			@use_rec.set_fsg(fsg_file, dict_file)      
		end
  else
    puts "Using ngram recognizer"
    @use_rec = RECOGNIZER
  end
  
  if $outdir != nil
     File.open("#{$outdir}/#{id}.info", 'w') { |f|
       req.env.select{ |k,v|
          f.write "#{k}: #{v}\n"
       }
    }
  end
  puts "User agent: " + req.user_agent
  device_id = get_user_device_id(req.user_agent)
  puts "Device ID : #{device_id}"
  cmn_mean = get_cmn_mean(device_id)
  if cmn_mean != nil
    puts "Setting CMN mean to #{cmn_mean}"
    @use_rec.set_cmn_mean(cmn_mean)
  end
    
  puts "Parsing content type " + req.content_type
  caps_str = content_type_to_caps(req.content_type)
  puts "CAPS string is " + caps_str
  @use_rec.clear(id, caps_str)
  
  length = 0
  
  left_over = ""
  req.body.each do |chunk|
    chunk_to_rec = left_over + chunk
    if chunk_to_rec.length > CHUNK_SIZE
      chunk_to_send = chunk_to_rec[0..(chunk_to_rec.length / 2) * 2 - 1]
      @use_rec.feed_data(chunk_to_send)
      left_over = chunk_to_rec[chunk_to_send.length .. -1]
    else
      left_over = chunk_to_rec
    end
    length += chunk.size
  end
  @use_rec.feed_data(left_over)
    
  
  puts "Got feed end"
  if length > 0
    @use_rec.feed_end()
    result = @use_rec.wait_final_result()
    set_cmn_mean(device_id, @use_rec.get_cmn_mean())
    
    puts "RESULT:" + result
    # only prettify results decoded using ngram
    if @use_rec == RECOGNIZER
      result = prettify(result)
      puts "PRETTY RESULT:" + result                          
    end
    linearizations = []
		if lm_name != nil and lm_name =~ /pgf$/
			output_langs = req.params['output-lang']
			if output_langs != nil
			  linearizations = []
			  output_langs.split(",").each do |output_lang|
			    puts "Linearizing result to lang #{output_lang}"
			    outputs = `echo "parse -lang=#{pgf_basename + input_lang} \\"#{result}\\" | linearize -lang=#{pgf_basename + output_lang}" | gf --run #{pgf_dir + '/' + pgf_basename + '.pgf'}`
			    
			    outputs.split("\n").each do |output|
			      if output != ""
						  linearizations.push({:output => output, :lang => output_lang})
						end
			    end
			    
			  end
			end
		end
    
    result = Iconv.iconv('utf-8', 'latin1', result)[0]
    linearizations.each do |l|
			l[:output] =  Iconv.iconv('utf-8', 'latin1', l[:output])[0]
		end
		

    
    
    
    headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
    if linearizations != nil
			JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [{:utterance => result, :linearizations => linearizations}]})
		else
		  JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [{:utterance => result}]})
		end
  else
    @use_rec.stop
    headers "Content-Type" => "application/json; charset=utf-8", "Content-Disposition" => "attachment"
    JSON.pretty_generate({:status => 0, :id => id, :hypotheses => [:utterance => ""]})
  end
end

error do
    puts "Error: " + env['sinatra.error']
    if @use_rec != nil and @use_rec.recognizing
      puts "Trying to clear recognizer.."
      @use_rec.stop
      puts "Cleared recognizer"
    end
    'Sorry, failed to process request. Reason: ' + env['sinatra.error'] + "\n"
end

def content_type_to_caps(content_type)
  if not content_type
    content_type = "audio/x-raw-int"
    return "audio/x-raw-int,rate=16000,channels=1,signed=true,endianness=1234,depth=16,width=16"
  end
  parts = content_type.split(%r{[,; ]})
  result = ""
  allowed_types = Set.new ["audio/x-flac", "audio/x-raw-int", "application/ogg", "audio/mpeg", "audio/x-wav",  ]
  if allowed_types.include? parts[0]
    result = parts[0]
    if parts[0] == "audio/x-raw-int"
      attributes = {"rate"=>"16000", "channels"=>"1", "signed"=>"true", "endianness"=>"1234", "depth"=>"16", "width"=>"16"}
      user_attributes = Hash[*parts[1..-1].map{|s| s.split('=', 2) }.flatten]
      attributes.merge!(user_attributes)
      result += ", " + attributes.map{|k,v| "#{k}=#{v}"}.join(", ")
    end
    return result
  else
    raise IOError, "Unsupported content type: #{parts[0]}. Supported types are: " + allowed_types.to_a.join(", ") + "." 
  end
end

def prettify(hyp)
  if $prettifier != nil
    $prettifier.puts hyp
    $prettifier.flush
    return $prettifier.gets.strip
  end
  return hyp
end

get '/fetch-jsgf' do 
  req = Rack::Request.new(env)
  url = req.params['lm']  
  if url == nil
    url = req.params['url']  
  end
  puts "Fetching JSGF grammar from #{url}"
  digest = MD5.hexdigest url
  content = open(url).read
  jsgf_file =  $config.fetch('grammar-dir', 'user_grammars') + "/#{digest}.jsgf"
  fsg_file =  fsg_file_from_url(url)
  dict_file =  dict_file_from_url(url)
  File.open(jsgf_file, 'w') { |f|
    f.write(content)
  }
  puts "Converting to FSG.."
  `#{$config.fetch('jsgf-to-fsg')} #{jsgf_file} #{fsg_file}`
  if $? != 0
    raise "Failed to convert JSGF to FSG" 
  end
  puts "Making dictionary.."
  `cat #{fsg_file} | #{$config.fetch('fsg-to-dict')} > #{dict_file}`
  if $? != 0
    raise "Failed to make dictionary from FSG" 
  end
  "Request completed"
end

get '/fetch-pgf' do
  req = Rack::Request.new(env)
  url = req.params['url']  
  input_langs = req['lang']
  if input_langs == nil
     input_langs = $config.fetch('gf', {}).fetch('default_input_lang', 'Est')
  end
  puts "Fetching PGF from #{url}"
  digest = MD5.hexdigest url
  content = open(url).read
  pgf_dir = $config.fetch('gf', {}).fetch('grammar-dir', 'user_gfs') + '/' + digest
  FileUtils.mkdir_p pgf_dir
  pgf_basename = File.basename(URI.parse(url).path, ".pgf")
  File.open(pgf_dir + '/' + pgf_basename + ".pgf", 'w') { |f|
    f.write(content)
  }
  puts 'Extracting concrete grammars'
  `gf -make --output-format=jsgf --output-dir=#{pgf_dir} #{pgf_dir + '/' + pgf_basename + ".pgf"}` 
  if $? != 0
    raise "Failed to make extract JSGF from PFG" 
  end

	input_langs.split(',').each do |lang|
	  jsgf_file = pgf_dir + '/' + pgf_basename + lang + ".jsgf"
	  fsg_file = pgf_dir + '/' + pgf_basename + lang + ".fsg"
	  dict_file = pgf_dir + '/' + pgf_basename + lang + ".dict"
	  puts "Making finite state grammar for input language #{lang}"
	  puts "Converting JSGF.."
	  `./scripts/convert-gf-jsgf.sh #{jsgf_file}`
    if $? != 0
      raise "Failed to convert JSGF for lang #{lang}" 
    end
    puts "Converting to FSG.."
    `#{$config.fetch('jsgf-to-fsg')} #{jsgf_file} #{fsg_file}`
    if $? != 0
      raise "Failed to convert JSGF to FSG for lang #{lang}" 
    end
    puts "Making dictionary.."
    `cat #{fsg_file} | #{$config.fetch('fsg-to-dict')} > #{dict_file}`
    if $? != 0
      raise "Failed to make dictionary from FSG for lang #{lang}" 
    end
	   
	end

  "Request completed"
end
  
  



def fsg_file_from_url(url)
  digest = MD5.hexdigest url
  return $config.fetch('grammar-dir', 'user_grammars') + "/#{digest}.fsg"
end

def dict_file_from_url(url)
  digest = MD5.hexdigest url
  return $config.fetch('grammar-dir', 'user_grammars') + "/#{digest}.dict"
end


def get_user_device_id(user_agent)
  # try to identify android device
  if user_agent =~ /.*\(RecognizerIntentActivity.* (\d+); .*/
    return $1
  end
  return "default"
end

def get_cmn_mean(device_id)
  cmn_means = {}
  begin
    cmn_means = YAML.load_file('cmn_means.yaml')
  rescue
  end
  return cmn_means.fetch(device_id, nil)
end 

def set_cmn_mean(device_id, mean)
  cmn_means = {}
  begin
    cmn_means = YAML.load_file('cmn_means.yaml')
  rescue
  end
  cmn_means[device_id] = mean
  File.open('cmn_means.yaml', 'w' ) do |out|
    YAML.dump( cmn_means, out )
  end
end
