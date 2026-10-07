require 'date'

module BusinessTime
  # A self-contained work calendar that can be passed to business time
  # calculations through the +:calendar+ option, or installed globally via
  # BusinessTime::Config.work_calendar.
  #
  # Compared to the global BusinessTime::Config, a WorkCalendar supports:
  #
  # * several work segments per day (e.g. a lunch break)
  # * segments that run past midnight (e.g. "20:00" - "02:00")
  # * versioned schedules that take effect on a given date
  # * holidays and temporary openings as real date ranges
  # * an explicit policy for DST gaps and repeated local times
  #
  # All arithmetic is performed on absolute (UTC) instants, so durations are
  # always real elapsed seconds; wall-clock times are only used to define
  # segment endpoints and are converted with the configured DST policy.
  #
  # Example:
  #
  #   calendar = BusinessTime::WorkCalendar.new(
  #     time_zone: "America/New_York",
  #     schedules: [
  #       { starts_on: Date.new(2024, 1, 1), hours: {
  #           mon: [["9:00", "12:00"], ["13:00", "17:00"]],
  #           fri: [["9:00", "17:00"], ["20:00", "2:00"]] } },
  #       { starts_on: Date.new(2024, 6, 1), hours: {
  #           mon: [["8:00", "12:00"], ["12:30", "16:30"]] } }
  #     ],
  #     holidays: [Date.new(2024, 7, 4)],
  #     extra_workdays: [{ Date.new(2024, 7, 6) => [["10:00", "14:00"]] }]
  #   )
  #
  #   calendar.add_business_seconds(time, 3600)
  #   calendar.subtract_business_seconds(time, 3600)
  #   calendar.business_time_until(time_a, time_b)
  class WorkCalendar
    # How to convert local segment endpoints that fall inside a DST
    # transition:
    #
    # * +:ambiguous+ - a local time that occurs twice (autumn fallback):
    #   +:first+ uses the first occurrence, +:last+ the second one.
    # * +:gap+ - a local time that never occurs (spring forward):
    #   +:shift_forward+ moves the endpoint to the next valid local time,
    #   +:raise+ raises an ArgumentError instead.
    DEFAULT_DST_POLICY = { ambiguous: :first, gap: :shift_forward }.freeze

    # Used for extra workdays that neither specify their own hours nor fall
    # on a weekday with scheduled segments.
    DEFAULT_EXTRA_HOURS = [["9:00", "17:00"]].freeze

    # Safety bound for add/subtract when a calendar stops having any
    # working time (e.g. a schedule version with no segments at all).
    MAX_LOOKAHEAD_DAYS = 366 * 25

    DAY_NAMES = %w(sun mon tue wed thu fri sat).freeze
    SECONDS_PER_DAY = 86_400

    attr_reader :time_zone, :dst_policy

    def initialize(hours: nil, schedules: nil, holidays: [], extra_workdays: [],
                   time_zone: nil, dst_policy: {}, default_hours: DEFAULT_EXTRA_HOURS)
      if hours && schedules
        raise ArgumentError, "pass either :hours or :schedules, not both"
      end

      @time_zone = self.class.normalize_zone(time_zone)
      @tzinfo = @time_zone && @time_zone.tzinfo
      @dst_policy = DEFAULT_DST_POLICY.merge(dst_policy)
      validate_dst_policy!

      @default_hours = default_hours && normalize_segments(default_hours)
      @schedules = normalize_schedules(hours, schedules)
      @holiday_ranges = Array(holidays).map { |entry| date_range(entry) }
      @extra_rules = normalize_extra_rules(extra_workdays)
      @interval_cache = {}

      if @extra_rules.empty? && @schedules.all? { |_, day_hours| day_hours.empty? }
        raise ArgumentError, "calendar defines no working hours"
      end
    end

    # Moves +time+ forward by +seconds+ business seconds. Negative values
    # move backwards. A time outside working hours rolls forward to the next
    # working interval first.
    def add_business_seconds(time, seconds)
      return subtract_business_seconds(time, -seconds) if seconds < 0

      moment = to_zone_time(time)
      date = moment.to_date
      remaining = seconds
      days_scanned = 0
      loop do
        daily_intervals(date).each do |interval_start, interval_end|
          next if interval_end <= moment
          from = interval_start > moment ? interval_start : moment
          available = interval_end - from
          return from + remaining if remaining <= available
          remaining -= available
        end
        date += 1
        days_scanned += 1
        raise "no working time within #{MAX_LOOKAHEAD_DAYS} days" if days_scanned > MAX_LOOKAHEAD_DAYS
      end
    end

    # Moves +time+ backwards by +seconds+ business seconds. Negative values
    # move forwards. A time outside working hours rolls back to the previous
    # working interval first.
    def subtract_business_seconds(time, seconds)
      return add_business_seconds(time, -seconds) if seconds < 0

      moment = to_zone_time(time)
      date = moment.to_date
      remaining = seconds
      days_scanned = 0
      loop do
        daily_intervals(date).reverse_each do |interval_start, interval_end|
          next if interval_start >= moment
          upto = interval_end < moment ? interval_end : moment
          available = upto - interval_start
          return upto - remaining if remaining <= available
          remaining -= available
        end
        date -= 1
        days_scanned += 1
        raise "no working time within #{MAX_LOOKAHEAD_DAYS} days" if days_scanned > MAX_LOOKAHEAD_DAYS
      end
    end

    # Real elapsed business seconds between +from+ and +to+. Negative when
    # +from+ is after +to+, mirroring Time#business_time_until.
    def business_time_until(from, to)
      time_a = to_zone_time(from)
      time_b = to_zone_time(to)
      direction = 1
      if time_a > time_b
        time_a, time_b = time_b, time_a
        direction = -1
      end

      total = 0.0
      date = time_a.to_date
      while date <= time_b.to_date
        daily_intervals(date).each do |interval_start, interval_end|
          clip_start = interval_start > time_a ? interval_start : time_a
          clip_end = interval_end < time_b ? interval_end : time_b
          total += clip_end - clip_start if clip_end > clip_start
        end
        date += 1
      end
      total * direction
    end

    # True when +time+ falls inside a working interval.
    def working?(time)
      moment = to_zone_time(time)
      daily_intervals(moment.to_date).any? do |interval_start, interval_end|
        moment >= interval_start && moment < interval_end
      end
    end

    # Merged working intervals (as [start, end) time pairs) that overlap the
    # given local date, including overnight tails from the previous day and
    # with holidays removed.
    def intervals_on(date)
      daily_intervals(to_date(date)).dup
    end

    private

    def self.normalize_zone(time_zone)
      case time_zone
      when nil
        nil
      when ActiveSupport::TimeZone
        time_zone
      when String
        zone = ActiveSupport::TimeZone[time_zone]
        raise ArgumentError, "unknown time zone: #{time_zone.inspect}" unless zone
        zone
      else
        if time_zone.respond_to?(:name)
          normalize_zone(time_zone.name)
        else
          raise ArgumentError, "unsupported time zone: #{time_zone.inspect}"
        end
      end
    end

    def validate_dst_policy!
      unless %i(first last).include?(@dst_policy[:ambiguous])
        raise ArgumentError, "dst_policy[:ambiguous] must be :first or :last"
      end
      unless %i(shift_forward raise).include?(@dst_policy[:gap])
        raise ArgumentError, "dst_policy[:gap] must be :shift_forward or :raise"
      end
    end

    def normalize_schedules(hours, schedules)
      raw = schedules || [{ starts_on: nil, hours: hours || {} }]
      raw.map do |entry|
        starts_on = entry[:starts_on] || entry["starts_on"]
        day_hours = entry[:hours] || entry["hours"]
        raise ArgumentError, "schedule is missing :hours" unless day_hours
        [starts_on && to_date(starts_on), normalize_hours(day_hours)]
      end.sort_by { |starts_on, _| starts_on || Date.new(1) }
    end

    def normalize_hours(day_hours)
      day_hours.each_with_object({}) do |(day, segments), normalized|
        normalized[normalize_wday(day)] = normalize_segments(segments)
      end
    end

    def normalize_wday(day)
      case day
      when Integer
        return day if (0..6).cover?(day)
      else
        index = DAY_NAMES.index(day.to_s.downcase[0, 3])
        return index if index
      end
      raise ArgumentError, "invalid weekday: #{day.inspect}"
    end

    # Segments are [start, end) pairs in seconds since local midnight. An
    # end at or before the start means the segment runs past midnight into
    # the next day.
    def normalize_segments(value)
      pairs = value
      pairs = [pairs] if pairs.is_a?(Array) && pairs.length == 2 && !pairs.first.is_a?(Array)
      pairs.map do |pair|
        unless pair.is_a?(Array) && pair.length == 2
          raise ArgumentError, "invalid segment: #{pair.inspect}"
        end
        segment_start = parse_day_time(pair[0])
        segment_end = parse_day_time(pair[1])
        segment_end += SECONDS_PER_DAY if segment_end <= segment_start
        if segment_end - segment_start > SECONDS_PER_DAY
          raise ArgumentError, "segment longer than 24 hours: #{pair.inspect}"
        end
        [segment_start, segment_end]
      end.sort
    end

    def parse_day_time(value)
      case value
      when ParsedTime
        value.hour * 3600 + value.min * 60 + value.sec
      when Numeric
        seconds = value.to_i
        return seconds if (0..SECONDS_PER_DAY).cover?(seconds)
        raise ArgumentError, "invalid day time: #{value.inspect}"
      when String
        match = /\A\s*(\d{1,2})(?::(\d{1,2}))?(?::(\d{1,2}))?\s*([ap]m)?\s*\z/i.match(value)
        raise ArgumentError, "invalid day time: #{value.inspect}" unless match
        hour = match[1].to_i
        minute = (match[2] || 0).to_i
        second = (match[3] || 0).to_i
        if match[4]
          raise ArgumentError, "invalid day time: #{value.inspect}" if hour > 12
          hour %= 12
          hour += 12 if match[4].downcase == "pm"
        end
        seconds = hour * 3600 + minute * 60 + second
        if hour > 24 || minute > 59 || second > 59 || seconds > SECONDS_PER_DAY
          raise ArgumentError, "invalid day time: #{value.inspect}"
        end
        seconds
      when Time, DateTime
        value.hour * 3600 + value.min * 60 + value.sec
      else
        raise ArgumentError, "invalid day time: #{value.inspect}"
      end
    end

    def normalize_extra_rules(extra_workdays)
      Array(extra_workdays).flat_map do |entry|
        if entry.is_a?(Hash)
          entry.map { |dates, segments| [date_range(dates), normalize_segments(segments)] }
        else
          [[date_range(entry), nil]]
        end
      end
    end

    def date_range(value)
      case value
      when Range
        to_date(value.begin)..to_date(value.end)
      else
        date = to_date(value)
        date..date
      end
    end

    def to_date(value)
      case value
      when Date then value
      when String then Date.parse(value)
      when Time, DateTime then value.to_date
      else
        raise ArgumentError, "invalid date: #{value.inspect}"
      end
    end

    def to_zone_time(time)
      if @time_zone
        time.in_time_zone(@time_zone)
      elsif time.is_a?(Time)
        time
      else
        time.to_time
      end
    end

    # The schedule version in effect on +date+: the latest one whose
    # starts_on is not after +date+, falling back to the earliest version.
    def schedule_for(date)
      chosen = @schedules.first[1]
      @schedules.each do |starts_on, day_hours|
        break if starts_on && starts_on > date
        chosen = day_hours
      end
      chosen
    end

    def holiday?(date)
      @holiday_ranges.any? { |range| range.cover?(date) }
    end

    def extra_segments_for(date)
      segments = []
      @extra_rules.each do |range, hours|
        next unless range.cover?(date)
        segments.concat(hours || scheduled_segments_for(date) || @default_hours || [])
      end
      segments
    end

    def scheduled_segments_for(date)
      segments = schedule_for(date)[date.wday]
      segments unless segments.nil? || segments.empty?
    end

    def daily_intervals(date)
      @interval_cache[date] ||= compute_daily_intervals(date)
    end

    def compute_daily_intervals(date)
      return [] if holiday?(date)

      day_start = absolute_time(date, 0)
      day_end = absolute_time(date + 1, 0)
      positives = positive_segments_starting(date)
      positives.concat(overnight_tails_into(date, day_start))
      merge_intervals(positives).filter_map do |interval_start, interval_end|
        clip_start = interval_start > day_start ? interval_start : day_start
        clip_end = interval_end < day_end ? interval_end : day_end
        [clip_start, clip_end] if clip_end > clip_start
      end
    end

    # Segments (schedule + temporary openings) that begin on +date+, as
    # absolute [start, end) pairs. Overnight segments keep their full extent
    # past midnight here; they are clipped per day by the caller.
    def positive_segments_starting(date)
      segments = []
      (schedule_for(date)[date.wday] || []).each do |segment_start, segment_end|
        segments << [absolute_time(date, segment_start), absolute_time(date, segment_end)]
      end
      extra_segments_for(date).each do |segment_start, segment_end|
        segments << [absolute_time(date, segment_start), absolute_time(date, segment_end)]
      end
      segments
    end

    def overnight_tails_into(date, day_start)
      positive_segments_starting(date - 1).select { |_, segment_end| segment_end > day_start }
    end

    # Merges overlapping and touching intervals so no span of time is ever
    # counted twice.
    def merge_intervals(intervals)
      intervals.sort_by(&:first).each_with_object([]) do |(interval_start, interval_end), merged|
        if merged.empty? || interval_start > merged[-1][1]
          merged << [interval_start, interval_end]
        elsif interval_end > merged[-1][1]
          merged[-1][1] = interval_end
        end
      end
    end

    # Converts a local wall-clock time (seconds since midnight on +date+)
    # into an absolute time using the configured DST policy.
    def absolute_time(date, seconds_of_day)
      date += seconds_of_day / SECONDS_PER_DAY
      seconds = seconds_of_day % SECONDS_PER_DAY
      hour, remainder = seconds.divmod(3600)
      minute, second = remainder.divmod(60)
      if @tzinfo
        local = Time.utc(date.year, date.month, date.day, hour, minute, second)
        local_to_utc(local).in_time_zone(@time_zone)
      else
        Time.local(date.year, date.month, date.day, hour, minute, second)
      end
    end

    def local_to_utc(local)
      periods = @tzinfo.periods_for_local(local)
      if periods.empty?
        case @dst_policy[:gap]
        when :raise
          raise ArgumentError, "local time #{local.strftime('%Y-%m-%d %H:%M:%S')} does not exist in #{@tzinfo.name}"
        else
          shift = 0
          while periods.empty?
            shift += 60
            raise ArgumentError, "local time #{local} is too deep inside a DST gap" if shift > 90_000
            periods = @tzinfo.periods_for_local(local + shift)
          end
          local += shift
        end
      end
      period = if @dst_policy[:ambiguous] == :last
                 periods.min_by(&:utc_total_offset)
               else
                 periods.max_by(&:utc_total_offset)
               end
      local - period.utc_total_offset
    end
  end
end
