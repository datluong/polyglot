require 'net/http'
require 'zip/zip' #require rubyzip gem
require 'zlib'
require 'benchmark'
require 'pp'

$VERSION = '0.1.2'

# required external data:
# radicals.txt   # defines description for each radical.
# radicals.zip   # defines characters for every radical/stroke count.
# strokes.txt    # defines availability of stroke counts per radicals.
#

module Polyglot
  @@radicals = nil
  @@local_dict = nil
  @@hanviet_dict = nil

  module Composition
    @@char_map = nil

    # @param   source_list  array of unicode characters
    # @param   composition  array
    # @param   options      :config  Character configuration.
    # @return  array of composition objects
    #
    def self.find(source_list, composition, options)
      options = options || {}
      puts "Polyglot::Composition::find #{composition.inspect}, source_size: #{source_list.size}, options: #{options}"
      map = self.get_char_map
      c_regex = options.key?(:config) ? Regexp.new(options[:config].to_s) : nil

      source_list.select do |ch|
        ok = false
        if map.key? ch
          entry_composition = map[ch][:composition]
          ok = composition.all? { |c| entry_composition.include? c }
          ok &&= (c_regex =~ map[ch][:configuration]) != nil unless c_regex.nil?
        end
        ok
      end
    end

    # Return an array of all characters containing composition
    #
    # @param  composition  An array of unicode characters.
    # @param   options      :config  Character configuration.
    #
    def self.find_all(composition, options)
      options = options || {}
      puts "Polyglot::Composition::find_all #{composition.inspect},  options: #{options}"
      results = []
      map = self.get_char_map
      c_regex = options.key?(:config) ? Regexp.new(options[:config].to_s) : nil

      map.each_pair do |k,v|
        ok = composition.all? { |c| v[:composition].include? c }
        ok &&= (c_regex =~ v[:configuration]) != nil unless c_regex.nil?
        results << k if ok
      end
      results
    end

    def self.get_char_map
      if @@char_map.nil?
        m = ::Benchmark.measure { @@char_map = self.expand self.build_hash if @@char_map.nil? }
        puts "Build char_map: #{m.total} secs"
      end
      @@char_map
    end

    def self.parse_cjk_line(line)
      comps = line.gsub(")", "").split ":"
      comps2 = comps.last.split "("
      return nil unless comps.size == 2 and comps2.size == 2
      h = { :char => comps.first, :configuration => comps2.first, :composition => comps2.last.split(","), :memorized => [] }
      h
    end

    def self.build_hash
      h = {}
      File.readlines("cjk-decomp-0.4.0.txt").each do |x|
        item = self.parse_cjk_line x.chomp
        h[item[:char]] = item unless item.nil?
      end
      h
    end

    #CharacterMap = Composition.build_hash
    def self.expand(char_map)
      char_map.keys.each_with_index do |key, _index|
        #next if _index > 5000
        entry = char_map[key]
        while (target_char = entry[:composition].find { |x| entry[:memorized].include?(x) == false }) != nil
          entry[:memorized] << target_char
          if char_map.key?(target_char)
            sub_composition = char_map[target_char][:composition]
            sub_composition.each { |sub_char| entry[:composition] << sub_char unless entry[:composition].include? sub_char }
          end
        end
      end
      char_map
    end

  end # end of Module Composition

  # provides interface for reading stardict dictionaries
  class Stardict

    def initialize dict_prefix
      @prefix   = dict_prefix
      @idx      = idx_data 
      @dict     = dict_data
      @wordlist = Hash.new
      parse
      puts "Stardict: Load #{dict_prefix} : Word(s): #{@wordlist.size}"
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

  #LOCAL_DICT = Stardict.new DICT_HANZIMASTER_PREFIX
  #LOCAL_DICT = Stardict.new DICT_CEDICT_PREFIX
  #HANVIET_DICT = Stardict.new DICT_HANVIET_PREFIX

  def self.get_local_dict
    if @@local_dict.nil?
      @@local_dict = Stardict.new DICT_CEDICT_PREFIX
    end
    @@local_dict
  end

  def self.get_hanviet_dict
    if @@hanviet_dict.nil?
      @@hanviet_dict = Stardict.new DICT_HANVIET_PREFIX
    end
    @@hanviet_dict
  end

  def self.use_dict_cedict
    @@local_dict = Stardict.new DICT_CEDICT_PREFIX 
    puts "Switched to CEDICT Dictionary"
  end

  def self.use_dict_hanzimaster
    @@local_dict = Stardict.new DICT_HANZIMASTER_PREFIX 
    puts "Switched to Hanzi Master Dictionary"
  end

  def self.use_dict_hanviet
    @@local_dict = Stardict.new DICT_HANVIET_PREFIX
    puts "Switched to Hanviet Dictionary"
  end

  # return hash #radical_number => radical_data
  def self.load_radicals
    lines = File.readlines 'radicals.txt'
    list  = lines.map { |l| l.split(",").map{ |x| x.strip } }
    hash  = Hash.new
    dup_hash = Hash.new

    rtable = list.map { |l|  { :radical_index => l.first.to_i,
                      :radical_name  => l[2],
                      :description   => l[1],
                      :unicode => l[1].split(" ").last
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

  def self.get_radicals
    @@radicals = self.load_radicals if @@radicals.nil?
    @@radicals
  end

  # return hash #radical_number => array of strokes
  def self.load_strokes
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
    stroke_list  = Polyglot::load_strokes
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

  # Return a list of radical objects by name
  #
  def self.list_radicals radical_name
    radicals = self.get_radicals
    radical_name = radical_name.sub("_","^") + "$" if radical_name.index("_") == 0
    regex    = Regexp.new "^#{radical_name}"
    matches  = radicals.select { |r| r[:radical_name] =~ regex }
    matches
  end

  # radical_name:
  #   - a number: look by radical index
  #   - a string: look by regex
  #   - prefix _: exact match
  def look radical_name, stroke_count = 0
    radical_name = radical_name.to_s if radical_name.is_a? Symbol
    #pi = radical_name.gsub(/[a-z]/,'').to_i
    #radical_name = pi if pi > 0

    radicals     = Polyglot::load_radicals
    stroke_map   = Polyglot::load_strokes

    matches = []

    if radical_name.is_a? String
      matches = Polyglot.list_radicals radical_name
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
    res = Polyglot::load_charlist radical_index, stroke_count

    charlist = Polyglot::parse_charlist res
    Polyglot::pretty_print charlist

    POLYGLOT_TMP[:RECENT] = charlist
    nil
  end

  # load data by stroke_count/radical from local zip archive
  # return sample: "25103:huy|25102:nhung|25101:thu|25100:tuat|"
  #
  # @param  stroke_count  Specify 0 to load all characters in given radical.
  #
  def self.load_charlist radical_index, stroke_count
    zip_entry_name = "radical-#{radical_index}.txt"
    raw            = Zip::ZipFile.open("radicals.zip") { |f| f.read zip_entry_name }
    stroke_table   = Hash.new
    regexp         = /\[([\d]+)\]/

    lines = raw.split("\n").each do |l|
      stroke               = regexp.match(l).to_a.last.to_i
      stroke_table[stroke] = l.sub(regexp,'').strip
    end

    return stroke_table[stroke_count] if stroke_count > 0
    stroke_table.values.join("|")
  end

  # sample data: "25103:huy|25102:nhung|25101:thu|25100:tuat|"
  # Return an array of character info {:char_code, :han, :unicode }
  #
  def self.parse_charlist text
    list = text.split("|").reject{ |x| x.empty? }.map { |x| x.split(":") }.map { |x| {
      :char_code => x[0],
      :han       => x[1],
      :unicode   => [x[0].to_i].pack("U*")
    } }

    # look up trans from local dictionary
    list.each do |x|
      trans = Polyglot.get_local_dict.trans x[:unicode]
      trans = "<no definition>" if trans.nil?
      x[:trans] = trans
    end

    list
  end

  def self.pretty_print charlist
    charlist.each_with_index { |x,_index| puts "#{x[:unicode]} #{x[:han].force_encoding('UTF-8')} #{x[:char_code].force_encoding('UTF-8')} ##{(_index+1).to_s.force_encoding('UTF-8')} #{x[:trans].force_encoding('UTF-8')}" }
  end

  def self.pretty_print_with_trans char_arr
    char_arr.each do |ch|
      trans = Polyglot.get_local_dict.trans(ch)
      trans = trans.force_encoding('UTF-8') unless trans.nil?

      hv_trans = Polyglot.get_hanviet_dict.trans(ch)
      if hv_trans != nil
        trans = "" if trans.nil?
        trans += " [hanviet] #{hv_trans.force_encoding('UTF-8')}"
      end

      trans = "<no definition>" if trans.nil?
      puts "#{ch} : #{trans}"
    end
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

  # Accept varargs
  # Example: composition :nhan1, :khau, :_si => look for all characters in :nhan1 radical, contains components: [:khau, :si]
  #          composition :nhan1, 6, :khau => look for all character in :nhan1 radical, 6 strokes, contains components: [:khau].
  #
  # You can also provide additional filtering options by passing a hash.
  #   Example: composition :nhuc,4, { configuration => :d }
  #
  # -- Character configuration table:
  #    Code regex    Meaning    Number of possible constituents
  #    c    component    0
  #    m.*    modified in some way, e.g. me=equivalent, msp=special, mo=outline, ml=left radical version    1
  #    w.*    second constituent contained within first in some way, e.g. w=within at the center, wbl=within at bottom left    2
  #    ba|d    second between first moving across or downwards    2
  #    lock    components locked together    2
  #    s.*    first component surrounds second, e.g. s=surrounds fully, str=surrounds around the top-right    2
  #    a    flows across    >= 2
  #    d    flows downwards    >= 2
  #    r.*    repeats and/or reflects in some way, e.g. refh=reflect horizontally, rot=rotate 180 degrees, rrefr= repeat with a reflection rightwards, ra=repeat across, r3d=repeat 3 times downwards, r3tr=repeat in a triangle, rst=repeat surrounding around the top    1
  #    The s, a, d, and r codes may be followed by /t, /m, /s, or /o, to show whether the join touches, molds, snaps together, or overlaps, respectively.

  def composition radical, *args
    options = args.find { |x| x.is_a? Hash }
    args.reject! { |x| x.is_a? Hash } unless options.nil?
    options = options || {}

    stroke_count = 0 # All strokes
    if args.size > 0 and args.first.is_a? Numeric
      stroke_count = args.first
      args.delete_at 0
    end

    main_matches = Polyglot.list_radicals radical.to_s
    if main_matches.size != 1
      puts "Main radical: #{radical}"
      pp main_matches
      return
    end

    radical_info = main_matches.first
    ri = radical_info[:radical_index]
    r_charlist = []
    unknown_r_comps = []

    radical_args = args.select { |x| x.is_a?(Symbol) and x.to_s =~ /[\w]+/ }
    char_args = args.select { |x| /[\w]+/.match(x.to_s).nil? }.map { |x| x.to_s }

    radical_args.each do |arg|
      if arg.is_a? Symbol
        matches = Polyglot.list_radicals arg.to_s
        unknown_r_comps << arg if matches.size != 1
        matches.each { |m| puts "#{m[:description]} #{m[:radical_name]}" } if matches.size > 1
        r_charlist << matches.first[:unicode] if matches.size == 1
      end
    end

    if unknown_r_comps.size > 0
      puts "Unknown radicals: #{unknown_r_comps.inspect}"
      return
    end

    charlist = Polyglot::parse_charlist Polyglot::load_charlist(ri, stroke_count)

    r_charlist = r_charlist.concat(char_args).uniq

    puts "Find: radical #{radical_info[:unicode]}, composition: #{r_charlist.inspect}, source: #{charlist.size} characters"

    r = Polyglot::Composition::find(charlist.map{|x| x[:unicode] }, r_charlist, options)
    puts "Found #{r.size} characters(s): #{r.inspect}"
    Polyglot.pretty_print_with_trans r

    POLYGLOT_TMP[:RECENT] = r
  end

  def composition_search *args
    options = args.find { |x| x.is_a? Hash }
    args.reject! { |x| x.is_a? Hash } unless options.nil?
    options = options || {}

    r_charlist = []
    unknown_r_comps = []

    radical_args = args.select { |x| x.is_a?(Symbol) and x.to_s =~ /[\w]+/ }
    char_args = args.select { |x| /[\w]+/.match(x.to_s).nil? }.map { |x| x.to_s }
    radical_args.each do |arg|
      if arg.is_a? Symbol
        matches = Polyglot.list_radicals arg.to_s
        unknown_r_comps << arg if matches.size != 1
        matches.each { |m| puts "#{m[:description]} #{m[:radical_name]}" } if matches.size > 1
        r_charlist << matches.first[:unicode] if matches.size == 1
      end
    end
    if unknown_r_comps.size > 0
      puts "Unknown radicals: #{unknown_r_comps.inspect}"
      return
    end
    r_charlist = r_charlist.concat(char_args).uniq

    r = Polyglot::Composition::find_all(r_charlist, options)
    puts "Found #{r.size} characters(s): #{r.inspect}"

    Polyglot.pretty_print_with_trans r
    POLYGLOT_TMP[:RECENT] = r
  end

  def c(*args)
    composition(*args)
  end

  def cs(*args)
    composition_search(*args)
  end

  def list_recents
    if POLYGLOT_TMP[:RECENT].is_a? Array
      POLYGLOT_TMP[:RECENT].each_with_index do |ch, _index|
        puts "#{_index}: #{ch}"
      end
    end
  end

  def show_composition(c)
    if c.is_a? Numeric
      c = POLYGLOT_TMP[:RECENT][c]
      c = c[:unicode] if c.is_a?(Hash) and c.key?(:unicode)
    end
    x = Composition::get_char_map[c.to_s]
    pp x
  end

  def cedict(ch)
    ch = ch.to_s.gsub('"', '')
    cmd = "cat cedict_ts.u8 | grep -e \"#{ch}\""
    puts `#{cmd}`
  end

  def cedict_word(ch)
    pattern = "^#{ch.to_s} "
    cedict pattern
  end

  # Get only the radical character from a character.
  #
  def extract_radical(ch)
    ch = ch.to_s
    map = Polyglot::Composition.get_char_map
    if map.key? ch
      comps = map[ch][:composition]
      return comps[0] if comps.size > 1
    end
    ch
  end

  def strip_radical(ch)
    ch = ch.to_s
    map = Polyglot::Composition.get_char_map
    if map.key? ch
      comps = map[ch][:composition]
      return comps[1] if comps.size > 1
    end
    ch
  end

  alias :sr :strip_radical
  alias :er :extract_radical

end # end of Module

include Polyglot
