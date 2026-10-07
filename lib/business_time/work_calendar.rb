module BusinessTime
  # A self-contained work calendar that can be passed independently of the
  # global BusinessTime::Config. It supports:
  #
  # * multiple work segments per day (e.g. a lunch break)
  # * segments that cross midnight (e.g. a night shift ending the next day)
  # * schedule versions that take effect on a given date
  # * holidays and temporary openings expressed as real date ranges
  # * explicit DST policies for repeated and missing local times
  #
  # All arithmetic is done in real elapsed seconds; wall-clock durations are
  # never mixed with absolute time. Forward addition, backward subtraction
  # and #business_time_until share the same half-open [start, end) interval
  # semantics, so adding N work seconds and subtracting them again returns
  # to the original moment (for moments inside work time).
  #
  # Example:
  #   calendar = BusinessTime::WorkCalendar.new(
  #     schedules: [
  #       { effective_from: Date.new(2026, 1, 1), weekly: {
  #           mon: [["09:00", "12:00"], ["13:00", "17:00"]],
  #           fri: [["09:00", "17:00"], ["20:00", "02:00"]],
  #       } },
  #       { effective_from: Date.new(2026, 10, 10), weekly: {
  #           mon: [["09:00", "12:00"], ["13:00", "17:00"]],
  #           sat: [["10:00", "14:00"]],
  #       } },
  #     ],
  #     holidays: [Date.new(2026, 10, 10)],
  #     openings: { Date.new(2026, 10, 11) => [["10:00", "12:00"]] },
  #     timezone: "America/New_York",
  #   )
  #   calendar.add_work_seconds(time, 3600)
  #   calendar.subtract_work_seconds(time, 3600)
  #   calendar.business_time_until(from, to)
  class WorkCalendar
    DAY_NAMES = %i(sun mon tue wed thu fri sat)
    MIDNIGHT = ParsedTime.new(0, 0, 0)
    # Upper bound when scanning for the next/previous work segment, so a
    # calendar without any work time fails loudly instead of looping.
    SCAN_LIMIT_DAYS = 3700

    attr_reader :timezone, :dst_ambiguous, :dst_gap

    # Options:
    #   weekly:        hash of day-name => [[start, end], ...]; shorthand for
    #                  a schedule that has always been in effect.
    #   schedules:     array of { effective_from:, weekly: } hashes. The
    #                  version with the latest effective_from <= date applies.
    #   holidays:      dates or date ranges on which no work happens. A
    #                  holiday clips a cross-midnight shift at 00:00.
    #   openings:      dates/ranges (or a hash of date/range => segments) that
    #                  temporarily override the schedule and holidays.
    #   timezone:      zone name or ActiveSupport::TimeZone used to interpret
    #                  segment wall times. Defaults to the system local zone.
    #   dst_ambiguous: :first (default) or :last - which occurrence of a
    #                  repeated local time to use.
    #   dst_gap:       :shift_forward (default), :shift_backward or :raise -
    #                  how to map a local time that does not exist.
    def initialize(weekly: nil, schedules: [], holidays: [], openings: [],
                   timezone: nil, dst_ambiguous: :first, dst_gap: :shift_forward)
      @versions = []
      @versions << { effective_from: nil, weekly: normalize_weekly(weekly) } if weekly
      Array(schedules).each do |schedule|
        @versions << {
          effective_from: coerce_date(schedule[:effective_from]),
          weekly: normalize_weekly(schedule[:weekly] || {}),
        }
      end
      @versions.sort_by! { |v| v[:effective_from] || Date.new(1, 1, 1) }

      @holidays = expand_dates(holidays)
      @openings = normalize_openings(openings)

      @timezone = timezone.is_a?(String) ? ActiveSupport::TimeZone[timezone] : timezone
      @dst_ambiguous = dst_ambiguous
      @dst_gap = dst_gap
      unless %i(first last).include?(@dst_ambiguous)
        raise ArgumentError, "dst_ambiguous must be :first or :last"
      end
      unless %i(shift_forward shift_backward raise).include?(@dst_gap)
        raise ArgumentError, "dst_gap must be :shift_forward, :shift_backward or :raise"
      end

      @segment_cache = {}
    end

    # Merged, non-overlapping [start, end) Time pairs covering the given
    # calendar date, including spillover from the previous day's
    # cross-midnight segments. Overlapping or touching segments are merged so
    # no interval is ever counted twice.
    def segments_on(date)
      date = coerce_date(date)
      segment_epochs_on(date).map do |start_epoch, end_epoch|
        [materialize_epoch(start_epoch), materialize_epoch(end_epoch)]
      end
    end

    # Total real work seconds on the given calendar date.
    def work_seconds_on(date)
      segment_epochs_on(coerce_date(date)).sum { |start_epoch, end_epoch| end_epoch - start_epoch }
    end

    # True when any work segment touches the given calendar date.
    def workday?(date)
      date = date.to_date if date.respond_to?(:to_date)
      segment_epochs_on(date).any?
    end

    # True when the moment falls inside a work segment.
    def during_work_hours?(time)
      epoch = to_epoch(time)
      segment_epochs_on(date_for_epoch(epoch)).any? { |s, e| epoch >= s && epoch < e }
    end

    # Signed count of real work seconds between two moments. Positive when
    # +to+ is after +from+, negative otherwise.
    def work_seconds_between(from, to)
      a = to_epoch(from)
      b = to_epoch(to)
      return -work_seconds_between(to, from) if b < a

      total = 0
      date = date_for_epoch(a)
      last_date = date_for_epoch(b)
      while date <= last_date
        segment_epochs_on(date).each do |s, e|
          lo = s > a ? s : a
          hi = e < b ? e : b
          total += hi - lo if hi > lo
        end
        date += 1
      end
      total
    end
    alias_method :business_time_until, :work_seconds_between

    # Moves +time+ forward by +seconds+ of work time. The result may land
    # exactly on a segment end (that much work has elapsed by then).
    def add_work_seconds(time, seconds)
      raise ArgumentError, "seconds must be non-negative" if seconds < 0

      remaining = seconds
      epoch = roll_forward_epoch(to_epoch(time))
      date = date_for_epoch(epoch)
      limit = date + SCAN_LIMIT_DAYS
      while date <= limit
        segment_epochs_on(date).each do |s, e|
          next if e <= epoch
          start = s > epoch ? s : epoch
          available = e - start
          return from_epoch_like(start + remaining, time) if remaining <= available
          remaining -= available
          epoch = e
        end
        date += 1
      end
      raise ArgumentError, "no work time found within #{SCAN_LIMIT_DAYS} days"
    end

    # Moves +time+ backward by +seconds+ of work time. The result may land
    # exactly on a segment start.
    def subtract_work_seconds(time, seconds)
      raise ArgumentError, "seconds must be non-negative" if seconds < 0

      remaining = seconds
      epoch = roll_backward_epoch(to_epoch(time))
      date = date_for_epoch(epoch)
      limit = date - SCAN_LIMIT_DAYS
      while date >= limit
        segment_epochs_on(date).reverse_each do |s, e|
          next if s >= epoch
          finish = e < epoch ? e : epoch
          available = finish - s
          return from_epoch_like(finish - remaining, time) if remaining <= available
          remaining -= available
          epoch = s
        end
        date -= 1
      end
      raise ArgumentError, "no work time found within #{SCAN_LIMIT_DAYS} days"
    end

    # Snaps +time+ to itself when inside work time, otherwise to the start of
    # the next work segment.
    def roll_forward(time)
      from_epoch_like(roll_forward_epoch(to_epoch(time)), time)
    end

    # Snaps +time+ to itself when inside work time (a segment end counts as
    # inside), otherwise to the end of the previous work segment.
    def roll_backward(time)
      from_epoch_like(roll_backward_epoch(to_epoch(time)), time)
    end

    private

    def normalize_weekly(weekly)
      weekly.each_with_object({}) do |(day, segments), normalized|
        day_index = DAY_NAMES.index(day.to_s.downcase.to_sym)
        raise ArgumentError, "unknown day name: #{day.inspect}" unless day_index
        normalized[DAY_NAMES[day_index]] = normalize_segments(segments)
      end
    end

    def normalize_segments(segments)
      segments.map do |pair|
        start_of_segment, end_of_segment = pair
        [parse_time_of_day(start_of_segment), parse_time_of_day(end_of_segment)]
      end
    end

    def parse_time_of_day(value)
      value.is_a?(ParsedTime) ? value : ParsedTime.parse(value.to_s)
    end

    def coerce_date(value)
      case value
      when Date then value
      when String then Date.parse(value)
      else value.to_date
      end
    end

    def expand_dates(values)
      Array(values).each_with_object(Set.new) do |value, dates|
        case value
        when Range
          value.each { |date| dates << coerce_date(date) }
        else
          dates << coerce_date(value)
        end
      end
    end

    def normalize_openings(openings)
      if openings.is_a?(Hash)
        openings.each_with_object({}) do |(dates, segments), normalized|
          expand_dates([dates]).each do |date|
            normalized[date] = segments && normalize_segments(segments)
          end
        end
      else
        expand_dates(openings).each_with_object({}) { |date, normalized| normalized[date] = nil }
      end
    end

    def holiday?(date)
      @holidays.include?(date)
    end

    def opening?(date)
      @openings.key?(date)
    end

    def scheduled_segments_for(date)
      version = @versions.reverse.find do |candidate|
        candidate[:effective_from].nil? || candidate[:effective_from] <= date
      end
      return [] unless version
      version[:weekly][DAY_NAMES[date.wday]] || []
    end

    # Absolute [start, end) Time pairs for segments *defined* on +date+.
    # Openings win over holidays, holidays win over the schedule. A segment
    # whose end is not after its start crosses midnight into the next day.
    def absolute_segments_defined_on(date)
      segments =
        if opening?(date)
          @openings[date] || scheduled_segments_for(date)
        elsif holiday?(date)
          return []
        else
          scheduled_segments_for(date)
        end

      segments.filter_map do |start_of_day, end_of_day|
        start_time = resolve_local(date, start_of_day)
        end_date = end_of_day <= start_of_day ? date + 1 : date
        end_time = resolve_local(end_date, end_of_day)
        [start_time, end_time] if end_time.to_i > start_time.to_i
      end
    end

    def segment_epochs_on(date)
      @segment_cache[date] ||= compute_segment_epochs_on(date)
    end

    def compute_segment_epochs_on(date)
      day_start = day_start_epoch(date)
      day_end = day_start_epoch(date + 1)
      raw = absolute_segments_defined_on(date - 1) + absolute_segments_defined_on(date)
      clipped = raw.filter_map do |start_time, end_time|
        lo = start_time.to_i > day_start ? start_time.to_i : day_start
        hi = end_time.to_i < day_end ? end_time.to_i : day_end
        [lo, hi] if lo < hi
      end
      clipped = [] if holiday?(date) && !opening?(date)
      merge_epochs(clipped)
    end

    def merge_epochs(pairs)
      pairs.sort.each_with_object([]) do |(s, e), merged|
        if merged.any? && s <= merged.last[1]
          merged.last[1] = e if e > merged.last[1]
        else
          merged << [s, e]
        end
      end
    end

    def day_start_epoch(date)
      resolve_local(date, MIDNIGHT).to_i
    end

    # Maps a wall-clock time of day on +date+ to an absolute time, applying
    # the configured DST policies for repeated and missing local times.
    def resolve_local(date, parsed)
      return Time.local(date.year, date.month, date.day, parsed.hour, parsed.min, parsed.sec) unless @timezone

      wall = Time.utc(date.year, date.month, date.day, parsed.hour, parsed.min, parsed.sec)
      periods = @timezone.tzinfo.periods_for_local(wall)
      case periods.size
      when 1
        @timezone.local(date.year, date.month, date.day, parsed.hour, parsed.min, parsed.sec)
      when 0
        resolve_gap(wall, parsed)
      else
        period = @dst_ambiguous == :last ? periods.min_by(&:utc_total_offset) : periods.max_by(&:utc_total_offset)
        (wall - period.utc_total_offset).in_time_zone(@timezone)
      end
    end

    def resolve_gap(wall, parsed)
      case @dst_gap
      when :raise
        raise ArgumentError, "local time #{parsed} does not exist in #{@timezone.name} (DST gap)"
      when :shift_forward
        shifted = wall
        shifted += 1 while @timezone.tzinfo.periods_for_local(shifted).empty?
        @timezone.local(shifted.year, shifted.month, shifted.day, shifted.hour, shifted.min, shifted.sec)
      when :shift_backward
        shifted = wall
        shifted -= 1 while @timezone.tzinfo.periods_for_local(shifted).empty?
        @timezone.local(shifted.year, shifted.month, shifted.day, shifted.hour, shifted.min, shifted.sec)
      end
    end

    def to_epoch(time)
      if time.is_a?(DateTime)
        time.to_time.to_i
      elsif time.is_a?(Date)
        day_start_epoch(time)
      else
        time.to_i
      end
    end

    def from_epoch_like(epoch, like)
      case like
      when ActiveSupport::TimeWithZone
        like.time_zone.at(epoch)
      when DateTime
        Time.at(epoch).to_datetime
      when Date
        date_for_epoch(epoch)
      else
        result = Time.at(epoch)
        like.respond_to?(:utc?) && like.utc? ? result.utc : result
      end
    end

    def materialize_epoch(epoch)
      @timezone ? @timezone.at(epoch) : Time.at(epoch)
    end

    def date_for_epoch(epoch)
      materialize_epoch(epoch).to_date
    end

    def roll_forward_epoch(epoch)
      date = date_for_epoch(epoch)
      limit = date + SCAN_LIMIT_DAYS
      while date <= limit
        segment_epochs_on(date).each do |s, e|
          return epoch if epoch >= s && epoch < e
          return s if epoch < s
        end
        date += 1
      end
      raise ArgumentError, "no work time found within #{SCAN_LIMIT_DAYS} days"
    end

    def roll_backward_epoch(epoch)
      date = date_for_epoch(epoch)
      limit = date - SCAN_LIMIT_DAYS
      while date >= limit
        segment_epochs_on(date).reverse_each do |s, e|
          return epoch if epoch > s && epoch <= e
          return e if epoch > e
        end
        date -= 1
      end
      raise ArgumentError, "no work time found within #{SCAN_LIMIT_DAYS} days"
    end
  end
end
