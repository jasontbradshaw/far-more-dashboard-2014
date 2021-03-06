require 'awesome_print'
require 'date'
require 'httparty'
require 'json'
require 'redis'
require 'stringio'
require 'zlib'

WUFOO_AUTH = { username: ENV["WUFOO_KEY"], password: "", }
FORM_URL_BASE = "https://theaustinstone.wufoo.com/api/v3/forms/far-more-involve/"
PAGE_SIZE = 100

REDIS = Redis.new(url: ENV["REDISCLOUD_URL"])
ENTRIES_CACHE_KEY_PREFIX = "wufoo_response_page_"
FIELDS_CACHE_KEY = "wufoo_form_fields"

WEEKS = 6 # show signups for the last six weeks, rolling
SECONDS_IN_A_WEEK = 60 * 60 * 24 * 7

WUFOO_API_DAILY_LIMIT = 5000
FULL_PAGE_CACHE_TIME = 60 * 60 * 3 # seconds
PARTIAL_PAGE_CACHE_TIME = ((60 * 60 * 24) / (WUFOO_API_DAILY_LIMIT / 1.5)).round # seconds

# how many adults attend each campus, keyed by the campus name as provided by
# the form.
CAMPUS_POPULATION_COUNTS = {
  "Downtown AM" => 2500,
  "Downtown PM" => 1600,
  "South" => 340,
  "St John AM" => 1100,
  "St John PM" => 260,
  "West" => 360,

  # FIXME: Get the actual count for this campus!
  "North" => 100,
}

def gzip(string)
  io = StringIO.new("w")
  w_gz = Zlib::GzipWriter.new(io, Zlib::BEST_COMPRESSION)
  w_gz.write(string)
  w_gz.close

  io.string
end

def gunzip(data)
  io = StringIO.new(data, "rb")
  gz = Zlib::GzipReader.new(io)

  gz.read
end

# get the JSON entries for the given page of a form. pages are always of size
# PAGE_SIZE. returns an array of entries in id-order.
def get_entries_by_page(page_number)
  key = ENTRIES_CACHE_KEY_PREFIX + page_number.to_s
  cached_response = REDIS.get(key)

  # decompress and return the cached response if it's already in redis
  if cached_response != nil
    return JSON.parse(gunzip(cached_response))
  end

  # otherwise, fetch and cache it
  resp = HTTParty.get(FORM_URL_BASE + "entries.json", query: {
    pageSize: PAGE_SIZE,
    pageStart: PAGE_SIZE * page_number,
  }, basic_auth: WUFOO_AUTH)

  # make sure we got a good response
  throw "Wufoo response error: #{resp.code}" if resp.code != 200

  # cache the response value
  entries = []
  REDIS.multi do
    entries = resp["Entries"] || entries

    # compress the entry data with GZip to increase the amount we can store in
    # our free Redis instance. it seems to compress _extremely_ well, down to 4%
    # of its original size in one instance!
    data = JSON.generate(entries)
    REDIS.set(key, gzip(data))

    # if the page was not full, expire the key after a short time so we'll
    # re-fetch the page in the future to check for new entries. this also
    # protects against constantly re-polling for the latest page.
    if entries.length < PAGE_SIZE
      REDIS.expire(key, PARTIAL_PAGE_CACHE_TIME)
    else
      # expire full pages after a while too, to ensure that we have relatively
      # up-to-date data at all times.
      REDIS.expire(key, FULL_PAGE_CACHE_TIME)
    end
  end

  entries
end

# return the fields spec for our form
def get_fields
  cached_response = REDIS.get(FIELDS_CACHE_KEY)

  # return the cached response if it's already in redis
  if cached_response != nil
    return JSON.parse(cached_response)
  end

  # otherwise, fetch and cache it
  resp = HTTParty.get(FORM_URL_BASE + "fields.json", basic_auth: WUFOO_AUTH)

  # make sure we got a good response
  throw "Wufoo response error: #{resp.code}" if resp.code != 200

  # cache the response value and set a long-ish TTL for it
  REDIS.multi do
    REDIS.set(FIELDS_CACHE_KEY, JSON.generate(resp))
    REDIS.expire(FIELDS_CACHE_KEY, 60 * 60 * 3)
  end

  resp["Fields"] || []
end

# returns all the entries in the form
def get_all_entries
  entries = []

  page_number = 0
  while true
    page_entries = get_entries_by_page(page_number)
    entries.concat(page_entries)

    # give up once we get a non-full page
    break if page_entries.length < PAGE_SIZE

    # continue to the next page
    page_number += 1
  end

  entries.map { |e| normalize_entry(e) }
end

STEP_SYMBOL = {
  "Attend" => :attend,
  "Serve"  => :serve,
  "Commit" => :commit,
  "Own"    => :own,
  "Lead"   => :lead,
}

CAMPUS_ATTEND_FIELD = {
  "Downtown AM"  => "Field229",
  "Downtown PM"  => "Field870",
  "St John AM"  => "Field865",
  "St John PM"  => "Field869",
  "West"  => "Field866",
  "South" => "Field867",
  "North" => "Field857", # Get involved field
}

CAMPUS_OWN_FIELD = {
  "Downtown AM"  => "Field240",
  "Downtown PM"  => "Field241",
  "St John AM"  => "Field242",
  "St John PM"  => "Field243",
  "West"  => "Field242",
  "South" => "Field245",
  "North" => "Field857", # Get involved field
}

CAMPUS_COMMIT_FIELD = {
  "Downtown AM"  => "Field230",
  "Downtown PM"  => "Field232",
  "St John AM"  => "Field234",
  "St John PM"  => "Field236",
  "West"  => "Field237",
  "South" => "Field238",
  "North" => "Field857", # Get involved field
}

CAMPUS_SERVE_FIELDS = {
  "Downtown AM"  => [127, 128, 129, 130, 131, 132, 133, 134],
  "Downtown PM"  => [247, 252, 248, 249, 250, 251, 253],
  "St John AM"  => [477, 488, 449, 450, 451, 452, 453, 454, 455],
  "St John PM"  => [547, 548, 549, 550, 551, 552],
  "West"  => [652, 653, 654, 655, 656, 657, 659],
  "South" => [752, 754, 756, 757, 759, 755, 759],
  "North" => [857], # Get involved field
}

# Normalize a service string to a nicer string.
NORMALIZED_TERMS = {
  #############
  # Service
  #############

  "Greeting" => "Welcome Team",
  "Setup"    => "Setup/Teardown",
  "Teardown" => "Setup/Teardown",
  "KIDS Registration"            => "KIDS",
  "The Office During the Week"   => "Office",

  # Identity, here for simplicity
  "Welcome" => "Welcome Team",
  "Parking" => "Parking Team",
  "Production" => "Production Team",
  "KIDS" => "KIDS",
  "STUDENTS" => "STUDENTS",
  "Hospitality" => "Hospitality Team",
  "Green Room" => "Green Room Team",
  "Prayer" => "Prayer Team",

  #############
  # Commit
  #############

  "Connect Class 9/21-10/12" => "Connect Class",
  "Connect Class 9/14-10/5"  => "Connect Class",
  "Connect Class 10/19-11/2" => "Connect Class",
  "Connect Lunch 9/21 and 9/28"       => "Connect Class",
  "Join a Missional Community" => "Missional Community",

  # Identity
  "Development Class"          => "Development Class",
  "Development Class beginning 10/19" => "Development Class",
  "Regional Event"             => "Regional Event",
  "Women's Gathering"          => "Women's Gathering",
  "STUDENTS Mailing List"      => "STUDENTS Mailing List",
  "Parent's Night Out"         => "Parent's Night Out",
  "Women's Equipping Class"    => "Women's Equipping",
  "Men's Equipping Class"      => "Men's Equipping",

  #############
  # Own
  #############

  "Partnership Class on 10/19" => "Partnership Class",
  "Becoming a Partner of the Austin Stone"  => "Partnership Class",
  "Partnership Class on 10/11" => "Partnership Class",
  "Partnership Class on 10/25" => "Partnership Class",
  "Partnership Class on 10/4"  => "Partnership Class",
  "Partnership Class on 10/12" => "Partnership Class",
  "Missional Community Training 10/26-11/16" => "MC Training",
  "Missional Community Training 10/19-11/2"  => "MC Training",
  "Missional Community Training 10/19-11/9"  => "MC Training",
  "Missional Community Training"   => "MC Training",

  # Duplicate, above:
  # "Connect me with my Campus Pastor Greg Breazeale (greg@austinstone.org)" => "Connect with pastor",
}

# Normalized Wufoo entry to hash:
#
#   {
#     first_name: String,
#     last_name: String,
#     campus: String,
#     step: String,
#     phone: String,
#     email: String,
#     created_at: DateTime,
#
#     # One of these keys will exist:
#     attend: String,
#     serve: Set[String],
#     commit: String,
#     own: String,
#     lead: String,
#   }
#
def normalize_entry(entry)
  norm = {
    first_name: entry["Field1"],
    last_name: entry["Field2"],
    email: entry["Field3"],
    phone: entry["Field4"],
    campus: entry["Field106"],
    step: entry["Field228"],
    created_at: DateTime.parse(entry["DateCreated"]).to_time,
  }

  step = STEP_SYMBOL[norm[:step]]
  case step
  when :attend
    norm[step] = entry[CAMPUS_ATTEND_FIELD[norm[:campus]]]
  when :commit
    norm[step] = NORMALIZED_TERMS[entry[CAMPUS_COMMIT_FIELD[norm[:campus]]]]
  when :own
    norm[step] = NORMALIZED_TERMS[entry[CAMPUS_OWN_FIELD[norm[:campus]]]]
  when :serve
    # User may sign up for multiple services. Get services for that user and
    # convert to normalized name.
    norm[step] = Set.new
    fields = CAMPUS_SERVE_FIELDS[norm[:campus]] || []
    fields.each do |field|
      val = entry["Field#{field}"]
      if val && !val.empty?
        norm[step] << NORMALIZED_TERMS[val]
      end
    end
  when :lead
    # Every lead option is to talk to a campus pastor
    norm[step] = :campus_pastor
  end

  norm
end

# Wufoo's API limit is 10000 requests/day, but we make at most one request every
# 10 seconds, plus refreshing the cached data once every three hours. this
# should put us slightly below the maximum number of daily requests.
SCHEDULER.every '10s', :first_in => 0 do
  # Total signups over weeks
  this_week = Time.now.to_i / SECONDS_IN_A_WEEK
  first_week = this_week - WEEKS
  weekly_counts = [0] * (WEEKS + 1)

  campus_counts = Hash.new { |h, k| h[k] = {label: k, value: 0, involvement: 0} }
  next_step_counts = Hash.new { |h, k| h[k] = {label: k, value: 0} }
  serve_commit_own_counts = Hash.new { |h, k| h[k] = {label: k, value: 0} }

  entries = get_all_entries
  entries.each do |entry|

    # Weekly counts
    week = entry[:created_at].to_i / SECONDS_IN_A_WEEK
    idx = week - first_week
    weekly_counts[idx] += 1

    # Campus leaderboard
    campus = entry[:campus]
    if !campus.nil? && campus.length > 0
      campus_counts[campus][:value] += 1

      # calculate involvement as we go
      campus_counts[campus][:involvement] = [
	100,
	(100.0 * campus_counts[campus][:value] / CAMPUS_POPULATION_COUNTS[campus]).round()
      ].min()
    end

    # Next step counts
    next_step_counts[entry[:step]][:value] += 1

    # Serve counts
    (entry[:serve] || []).each do |service|
      # Skip if they haven't chosen a service to do
      serve_commit_own_counts[service][:value] += 1 unless service.nil?
    end

    # Commit and Own counts
    [:commit, :own].each do |key|
      if !entry[key].nil? && !entry[key].empty?
	serve_commit_own_counts[entry[key]][:value] += 1
      end
    end
  end

  # Calculate total involvement
  total_count = campus_counts.values
      .map { |campus| campus[:value] }
      .inject { |sum, x| sum + x }
  involvement_total = [
    100,
    (100.0 * total_count / CAMPUS_POPULATION_COUNTS.values.inject { |sum, x| sum + x }).round()
  ].min()

  # Get weekly counts
  points = []
  weekly_counts.each_with_index { |count, idx| points << {x: idx, y: count} }

  # Sort counts descending.
  campus_sorted = campus_counts.values.sort_by { |blob| -blob[:value] }
  next_step_sorted = next_step_counts.values.sort_by { |blob| -blob[:value] }
  serve_commit_own_sorted = serve_commit_own_counts.values.sort_by { |blob| -blob[:value] }

  # Send events
  send_event('farmore-next-step', value: next_step_sorted)
  send_event('farmore-serve-commit-own', items: serve_commit_own_sorted)
  send_event('farmore-campus-leaderboard', items: campus_sorted)
  send_event('signup-total', value: entries.count)
  send_event('farmore-weekly', points: points)

  send_event('farmore-involvement-dtam', value: campus_counts["Downtown AM"][:involvement])
  send_event('farmore-involvement-dtpm', value: campus_counts["Downtown PM"][:involvement])
  send_event('farmore-involvement-north', value: campus_counts["North"][:involvement])
  send_event('farmore-involvement-south', value: campus_counts["South"][:involvement])
  send_event('farmore-involvement-stjam', value: campus_counts["St John AM"][:involvement])
  send_event('farmore-involvement-stjpm', value: campus_counts["St John PM"][:involvement])
  send_event('farmore-involvement-west', value: campus_counts["West AM"][:involvement])
  send_event('farmore-involvement-total', value: involvement_total)
end

SCHEDULER.every '15s', :first_in => 0 do
  entries = get_all_entries()
  sentences = entries.last(50).map do |entry|
    name = ""

    # Build initials, allowing:
    # - first, last
    # - first
    first_name = entry[:first_name]
    if !first_name.try(:empty?)
      name += first_name[0].upcase

      last_name = entry[:last_name]
      if !last_name.try(:empty?)
        name += ".#{last_name[0].upcase}."
      end
    else
      # No name given
      name = "Someone"
    end

    step = STEP_SYMBOL[entry[:step]]
    sentence = "#{name}'s next step is to #{step.upcase}"

    transition = case step
                 when :commit
                   " to a "
		 when :own
		   " the mission by participating in "
                 when :lead
                   ""
                 when :serve
                   " in "
                 else # :attend
                   " more regularly."
                 end

    sentence += transition

    case step
    when :serve
      areas = entry[step].select { |v| !v.nil? && !v.empty? }

      if areas.length > 2
        sentence += areas[0...-1].join(", ")
        sentence += ", and " + areas[-1]
      else
        sentence += areas.join(" and ")
      end
    when :lead
    else
      sentence += entry[step].to_s
    end

    if !["!", "."].include?(sentence[-1])
      # Need to add period at end
      sentence += "."
    end

    "From our #{entry[:campus].upcase} campus: #{sentence}"
  end

  send_event('real-time-feed', texts: sentences, count: entries.count)
end
