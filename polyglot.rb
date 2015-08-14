require 'net/http'
require 'zip/zip' #require rubyzip gem
require 'zlib'

$VERSION = '0.1.1'

# required external data:
# radicals.txt   # defines description for each radical.
# radicals.zip   # defines characters for every radical/stroke count.
# strokes.txt    # defines availability of stroke counts per radicals.
#

module Polyglot

  
  # provides interface for reading stardict dictionaries
  class Stardict

    def initialize dict_prefix
      puts "Stardict: Load #{dict_prefix}"
      @prefix   = dict_prefix
      @idx      = idx_data 
      @dict     = dict_data
      @wordlist = Hash.new
      parse
    end

    # parse dictionary contents
    #
    def parse
      regexp  = /([\d\D]+?\x00[\d\D]{8})/
      entries = @idx.scan(regexp).map { |x| x.first }

      entries.each do |entry|
        zero_index = entry.index "\x00"
        word       = entry[0,zero_index].force_encoding "UTF-8"
        d_location = entry[entry.length - 8, 4].unpack("N").first
        d_size     = entry[entry.length - 4, 4].unpack("N").first

        @dict.seek d_location
        trans = @dict.read d_size

        @wordlist[word] += "\n#{trans}" if @wordlist.key? word
        @wordlist[word]  = trans        unless @wordlist.key? word
      end

      # normalize definitions
      pinyin_regexp = /([\w+]*\d)/ 
      @wordlist.keys.each do |word|
        trans = @wordlist[word].gsub("\n", ", ")

        unless @prefix =~ /hanzim/
          match = pinyin_regexp.match trans
          if match
            c = match.to_a.first
            trans.sub! c, "[#{c}] "
          end
        end

        @wordlist[word] = trans
      end
    end

    def trans word
      return @wordlist[word] if @wordlist.has_key? word
      nil
    end

    def wordlist
      @wordlist
    end

    def idx_data
      get_data "#{@prefix}.idx", "#{@prefix}.idx.gz"
    end

    def dict_data
      StringIO.new(get_data("#{@prefix}.dict","#{@prefix}.dict.dz"))
    end

    def get_data(file,gz)
      begin
        File.open(file,'rb'){|f|f.read}
      rescue
        begin
          Zlib::GzipReader.open(gz){|f|f.read}
        rescue
      raise IOError, "can not open '#{file}' or gz '#{gz}'"
        end
      end
    end

  end # end of class Stardict


  POLYGLOT_TMP = {}
  DICT_CEDICT_PREFIX = "dict/cedict-gb/cedict-gb"
  DICT_HANVIET_PREFIX = "dict/hanviet/hanviet"
  DICT_HANZIMASTER_PREFIX = "dict/hanzim/hanzim"
  DICT_XDICT_CE_GB_PREFIX = "dict/stardict-xdict-ce-gb-2.4.2/xdict-ce-gb"
  DICT_LAZYWORM_PREFIX = "dict/stardict-lazyworm-ce-2.4.2/lazyworm-ce"

#  LOCAL_DICT = Stardict.new DICT_HANZIMASTER_PREFIX
  LOCAL_DICT = Stardict.new DICT_CEDICT_PREFIX

  def use_dict_cedict
    #LOCAL_DICT = Stardict.new DICT_CEDICT_PREFIX 
    puts "Switched to CEDICT Dictionary"
  end

  def use_dict_hanzimaster
    #LOCAL_DICT = Stardict.new DICT_HANZIMASTER_PREFIX 
    puts "Switched to Hanzi Master Dictionary"
  end

  def use_dict_hanviet
    #LOCAL_DICT = Stardict.new DICT_HANVIET_PREFIX
    puts "Switched to Hanviet Dictionary"
  end

  # return hash #radical_number => radical_data
  def load_radicals
    lines = File.readlines 'radicals.txt'
    list  = lines.map { |l| l.split(",").map{ |x| x.strip } }
    hash  = Hash.new
    dup_hash = Hash.new

    rtable = list.map { |l|  { :radical_index => l.first.to_i,
                      :radical_name  => l[2],
                      :description   => l[1]
                    } 
             }

    rnames = rtable.map { |l| l[:radical_name] }
    dups   = rnames.select{ |x| rnames.select {|y| y == x}.size > 1 }.uniq
    dups.each { |d| dup_hash[d] = 1 }

    # create index suffix for each duplicated radical name
    rtable.each do |l|
      rname = l[:radical_name]
      if dup_hash.has_key? rname
        count = dup_hash[rname]
        l[:radical_name] = "#{l[:radical_name]}#{count}"
        dup_hash[rname] = count+1
      else
        dup_hash[rname] = 1
      end
    end
    
    rtable
  end

  # return hash #radical_number => array of strokes
  def load_strokes
    lines = File.readlines 'strokes.txt'
    list  = lines.map { |l| l.strip.split(":") }
    hash  = Hash.new
    list.each { |l| hash[l.first.to_i] = l.last.split("|").map { |x| x.to_i } }
    hash
  end

  def download_radical_strokes
    fname = 'strokes.txt'
    (1..214).each do |x|
      uri = URI("http://www.hanviet.org/ajax.php?radical=#{x}")
      puts "loading #{uri}.."
      res = Net::HTTP.get uri
      res = "#{x}:#{res}\n"
      f = File.open(fname, 'a') { |f| f.write(res) }
    end
  end

  def download_charlist radical_index
    puts "Downloading Characters for radical #{radical_index}"
    stroke_list  = load_strokes 
    stroke_table = stroke_list[radical_index]

    res_table = stroke_table.map do |stroke_count|
      uri = URI("http://www.hanviet.org/ajax.php?radical=#{radical_index}&strokes=#{stroke_count}")
      puts uri
      s   = Net::HTTP.get uri
      s2  = "[#{stroke_count.to_s.force_encoding('UTF-8')}] #{s}"
    end

    File.open("radical-#{radical_index}.txt","w") { |f| f.write res_table.join("\n") }
    res_table
  end

  def l a,b=0
    look a,b
  end

  def r a,b=0
    look a,b
  end

  # radical_name: 
  #   - a number: look by radical index
  #   - a string: look by regex
  #   - prefix _: exact match
  def look radical_name, stroke_count = 0
    radical_name = radical_name.to_s if radical_name.is_a? Symbol
    #pi = radical_name.gsub(/[a-z]/,'').to_i
    #radical_name = pi if pi > 0

    radicals     = load_radicals 
    stroke_map   = load_strokes

    matches = []

    if radical_name.is_a? String
      radical_name = radical_name.sub("_","^") + "$" if radical_name.index("_") == 0
      regex    = Regexp.new "^#{radical_name}"
      matches  = radicals.select { |r| r[:radical_name] =~ regex }
      if matches.size == 0
        puts "No radical #{radical_name}"
        return
      end

      if matches.size > 1
        matches.each { |m| puts "#{m[:description]} #{m[:radical_name]}" }
        return
      end

    end

    matches = radicals.select { |r| r[:radical_index] == radical_name } if radical_name.is_a? Fixnum

    puts matches.first[:description]
    radical_index = matches.first[:radical_index] 
    stroke_table  = stroke_map[matches.first[:radical_index]]
    return puts "Available Strokes: #{stroke_table}" if stroke_count == 0
    return puts "No characters with #{stroke_count} strokes" unless stroke_table.include? stroke_count
    
    puts "Looking up.."
    #load input string from server
    #uri = URI("http://www.hanviet.org/ajax.php?radical=#{radical_index}&strokes=#{stroke_count}")
    #res = Net::HTTP.get(uri).strip    
    res = load_charlist radical_index, stroke_count

    charlist = parse_charlist res
    pretty_print charlist

    POLYGLOT_TMP[:RECENT] = charlist
    nil
  end

  # load data by stroke_count/radical from local zip archive
  # return sample: "25103:huy|25102:nhung|25101:thu|25100:tuat|"
  #
  def load_charlist radical_index, stroke_count
    zip_entry_name = "radical-#{radical_index}.txt"
    raw            = Zip::ZipFile.open("radicals.zip") { |f| f.read zip_entry_name }
    stroke_table   = Hash.new
    regexp         = /\[([\d]+)\]/

    lines = raw.split("\n").each do |l|
      stroke               = regexp.match(l).to_a.last.to_i
      stroke_table[stroke] = l.sub(regexp,'').strip
    end

    stroke_table[stroke_count]
  end
  
  # sample data: "25103:huy|25102:nhung|25101:thu|25100:tuat|"
  #
  def parse_charlist text
    list = text.split("|").map { |x| x.split(":") }.map { |x| {
      :char_code => x[0],
      :han       => x[1],
      :unicode   => [x[0].to_i].pack("U*")
    } }

    # look up trans from local dictionary
    list.each do |x|
      trans = LOCAL_DICT.trans x[:unicode]
      trans = "<no definition>" if trans.nil?
      x[:trans] = trans
    end
  end

  def pretty_print charlist
    charlist.each_with_index { |x,_index| puts "#{x[:unicode]} #{x[:han].force_encoding('UTF-8')} #{x[:char_code].force_encoding('UTF-8')} ##{(_index+1).to_s.force_encoding('UTF-8')} #{x[:trans].force_encoding('UTF-8')}" }
  end

  # get the pinyin of char_code
  #
  def pinyin char_code
    # look up in recent_table
    if char_code < 1000
      char_code = POLYGLOT_TMP[:RECENT][char_code-1][:char_code].to_i
    end

    uri   = URI("http://www.hanviet.org/hv_timchu.php?unichar=#{char_code}")
    res   = Net::HTTP.get uri
    regex = /javascript:mandarin\('([\w]+)'\)/ 
    match = regex.match res
    return puts "Can't find pinyin for char #{char_code}" if match.nil?
    uchar = [char_code].pack "U*"
    puts "#{uchar} #{match.to_a.last}"
  end

  def p char_code
    pinyin char_code
  end

end # end of Module

include Polyglot 