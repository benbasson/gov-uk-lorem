require 'sinatra'
require 'active_support/core_ext/time'
require 'haml'
require 'feedjira'
require 'nokogiri'
require 'rdiscount'

TELEPHONE_NUMBER_REGEX = /([0-9]+\s){3,}/
FILE_SIZE_REGEX = /[0-9]+\.?[0-9]*\s?(KB|MB)/i
GOV_UK_ANNOUNCEMENTS_URL = 'https://www.gov.uk/government/announcements.atom'
DEFAULT_PARAGRAPHS = 5
DEFAULT_MIN_WORDS = 20
MAX_PARAGRAPHS = 50
CACHE_TIMEOUT_SECONDS = 3600 # an hour

# Simple cache
Cache = { :feed => nil, :feed_updated => nil }

configure do
  set :server, 'thin'
  set :haml, :attr_wrapper => '"'
  set :feed, nil
  set :feed_updated, nil
end

helpers do
  def number_or_nil (string = '')
    Integer(string)
  rescue ArgumentError, TypeError
    nil
  end
end

get '/:paragraphs?' do
  # default the parameters if not specified
  num_paragraphs = number_or_nil(params['paragraphs']) || DEFAULT_PARAGRAPHS
  min_words = number_or_nil(params['minimum-word-count']) || DEFAULT_MIN_WORDS

  # basic input sanitisation
  if num_paragraphs > MAX_PARAGRAPHS
    num_paragraphs = MAX_PARAGRAPHS
  elsif num_paragraphs < 1
    num_paragraphs = 1
  end

  # more basic input sanitisation
  if min_words < 1
    min_words = 1
  end

  # make sure we don't hit GOV.UK every time a request is made (once an hour should suffice)
  if Cache[:feed_updated].nil? or Cache[:feed_updated] < Time.now.ago(CACHE_TIMEOUT_SECONDS)
    # if we fail to fetch the announcement, or it serves garbage, or another error occurs
    # then fall back to reading from the local filesystem (known, safe version of the feed)
    begin
      Cache[:feed] = Feedjira::Feed.fetch_and_parse GOV_UK_ANNOUNCEMENTS_URL
      puts 'Successfully fetched GOV.UK Announcements'
    rescue
      fallback_xml = File.read('./fallback/announcements-fallback.atom')
      Cache[:feed] = Feedjira::Feed.parse_with(Feedjira::Parser::Atom, fallback_xml)
      puts 'Failed to fetch GOV.UK Announcements, using local fallback'
    end

    Cache[:feed_updated] = Time.now
  end

  # cache dereference for convenience
  feed = Cache[:feed]
  text_fragments = Set.new

  # limit to the first 20 entries (may span a few days, but that's ok)
  feed.entries.first(20).each do |entry|
    html = Nokogiri::HTML(entry.content)
    # get the paragraphs from the HTML fragment, ignore other elements
    html.search('p').each do |p|
      # extract the text and retain it if it doesn't match this list of
      # undesirable traits
      text = p.text
      text_fragments.add text unless
        text.include? '@' or # exclude paragraphs that are mostly contact details
          text.match TELEPHONE_NUMBER_REGEX or # exclude paragraphs that are mostly contact details
          text.match FILE_SIZE_REGEX or # exclude paragraphs that contain file size information
          text.include? 'Thank you' or # exclude personal messages of thanks
          text.include? ':' or # exclude lists and/or news item style snippets
          text.split(/\s/).size < min_words # exclude anything with fewer words than requested
    end
  end

  # pass results to template
  @fragments = text_fragments.to_a.sample(num_paragraphs)
  @num_paragraphs = num_paragraphs
  @min_words = min_words
  haml :index
end

get '/service-status' do
  content_type 'text/plain'
  "Up and running: #{Time.now.to_formatted_s :db}" 
end
