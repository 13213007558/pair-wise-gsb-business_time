require 'helper'

describe "work calendar" do
  # One week of data: Mon 2026-10-05 .. Sun 2026-10-11.
  # * Monday has a lunch break (two segments)
  # * Friday has a night shift crossing midnight into Saturday
  # * a new schedule version takes effect on Saturday 2026-10-10
  # * Saturday 2026-10-10 is a holiday (clipping the Friday night shift)
  # * Sunday 2026-10-11 is a temporary opening
  let(:week_one) do
    {
      mon: [["09:00", "12:00"], ["13:00", "17:00"]],
      tue: [["09:00", "17:00"]],
      wed: [["09:00", "17:00"]],
      thu: [["09:00", "17:00"]],
      fri: [["09:00", "17:00"], ["20:00", "02:00"]],
    }
  end

  let(:week_two) do
    {
      mon: [["09:00", "12:00"], ["13:00", "17:00"]],
      tue: [["09:00", "17:00"]],
      wed: [["09:00", "17:00"]],
      thu: [["09:00", "17:00"]],
      fri: [["09:00", "17:00"]],
      sat: [["10:00", "14:00"]],
    }
  end

  let(:calendar) do
    BusinessTime::WorkCalendar.new(
      schedules: [
        { effective_from: Date.new(2026, 1, 1), weekly: week_one },
        { effective_from: Date.new(2026, 10, 10), weekly: week_two },
      ],
      holidays: [Date.new(2026, 10, 10)],
      openings: { Date.new(2026, 10, 11) => [["10:00", "12:00"]] },
    )
  end

  def t(*args)
    Time.local(*args)
  end

  describe "multiple segments per day" do
    it "exposes the morning and afternoon segments on Monday" do
      segments = calendar.segments_on(Date.new(2026, 10, 5))
      assert_equal [[t(2026, 10, 5, 9), t(2026, 10, 5, 12)],
                    [t(2026, 10, 5, 13), t(2026, 10, 5, 17)]], segments
    end

    it "does not count the lunch break as work time" do
      assert_equal 7 * 3600, calendar.work_seconds_on(Date.new(2026, 10, 5))
      assert_equal 2 * 3600, calendar.business_time_until(t(2026, 10, 5, 11), t(2026, 10, 5, 14))
    end

    it "jumps over the lunch break when adding work seconds" do
      assert_equal t(2026, 10, 5, 12, 0, 0), calendar.add_work_seconds(t(2026, 10, 5, 11, 59, 59), 1)
      assert_equal t(2026, 10, 5, 13, 0, 1), calendar.add_work_seconds(t(2026, 10, 5, 12, 0, 0), 1)
    end

    it "jumps back over the lunch break when subtracting work seconds" do
      assert_equal t(2026, 10, 5, 11, 59, 59), calendar.subtract_work_seconds(t(2026, 10, 5, 13, 0, 0), 1)
    end
  end

  describe "cross-midnight segments and holidays" do
    it "counts the Friday night shift up to midnight when Saturday is a holiday" do
      assert_equal 4 * 3600, calendar.business_time_until(t(2026, 10, 9, 19), t(2026, 10, 10, 12))
      assert_equal 4 * 3600, calendar.business_time_until(t(2026, 10, 9, 20), t(2026, 10, 10, 2))
    end

    it "treats the holiday Saturday as a non-workday" do
      assert_equal false, calendar.workday?(Date.new(2026, 10, 10))
      assert_equal 0, calendar.work_seconds_on(Date.new(2026, 10, 10))
    end

    it "supports holidays given as date ranges" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { mon: [["09:00", "17:00"]], tue: [["09:00", "17:00"]], wed: [["09:00", "17:00"]] },
        holidays: [Date.new(2026, 10, 6)..Date.new(2026, 10, 7)],
      )
      assert_equal false, cal.workday?(Date.new(2026, 10, 6))
      assert_equal false, cal.workday?(Date.new(2026, 10, 7))
      assert_equal true, cal.workday?(Date.new(2026, 10, 5))
    end
  end

  describe "schedule versions" do
    it "applies the old schedule before the switch date" do
      assert_equal 3 * 3600, calendar.business_time_until(t(2026, 10, 9, 20), t(2026, 10, 9, 23))
    end

    it "applies the new schedule from its effective date" do
      # Saturday shift only exists in the new version; the holiday hides it
      # on 2026-10-10 itself, but it is there the week after.
      assert_equal [[t(2026, 10, 17, 10), t(2026, 10, 17, 14)]], calendar.segments_on(Date.new(2026, 10, 17))
      # and the Friday night shift is gone under the new version
      assert_equal 0, calendar.business_time_until(t(2026, 10, 16, 20), t(2026, 10, 17, 0))
      assert_equal 8 * 3600, calendar.work_seconds_on(Date.new(2026, 10, 16))
    end
  end

  describe "temporary openings" do
    it "makes a non-working day workable with custom segments" do
      assert_equal true, calendar.workday?(Date.new(2026, 10, 11))
      assert_equal [[t(2026, 10, 11, 10), t(2026, 10, 11, 12)]], calendar.segments_on(Date.new(2026, 10, 11))
      assert_equal 2 * 3600, calendar.business_time_until(t(2026, 10, 11, 9), t(2026, 10, 11, 13))
    end

    it "wins over a holiday and falls back to the scheduled segments" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sat: [["09:00", "12:00"]] },
        holidays: [Date.new(2026, 10, 3)],
        openings: [Date.new(2026, 10, 3)],
      )
      assert_equal true, cal.workday?(Date.new(2026, 10, 3))
      assert_equal 3 * 3600, cal.work_seconds_on(Date.new(2026, 10, 3))
    end
  end

  describe "merging overlapping segments" do
    let(:overlapping) do
      BusinessTime::WorkCalendar.new(
        weekly: { tue: [["09:00", "17:00"], ["12:00", "18:00"], ["19:00", "20:00"]] },
      )
    end

    it "merges overlapping and touching segments" do
      assert_equal [[t(2026, 10, 6, 9), t(2026, 10, 6, 18)],
                    [t(2026, 10, 6, 19), t(2026, 10, 6, 20)]], overlapping.segments_on(Date.new(2026, 10, 6))
    end

    it "never counts an interval twice" do
      assert_equal 10 * 3600, overlapping.work_seconds_on(Date.new(2026, 10, 6))
    end
  end

  describe "consistent interval semantics" do
    it "returns to the original moment after adding and subtracting N seconds" do
      [
        t(2026, 10, 7, 10, 30, 15), # mid-segment
        t(2026, 10, 5, 11, 30, 0),  # crossing the lunch break
        t(2026, 10, 5, 9, 0, 0),    # exactly on a segment start
        t(2026, 10, 9, 21, 0, 0),   # night shift clipped by the holiday
      ].each do |moment|
        [1, 1000, 10_000].each do |n|
          shifted = calendar.add_work_seconds(moment, n)
          assert_equal moment, calendar.subtract_work_seconds(shifted, n),
            "expected add/subtract of #{n}s to round-trip #{moment}"
        end
      end
    end

    it "agrees between add and business_time_until" do
      from = t(2026, 10, 5, 10, 15, 0)
      to = calendar.add_work_seconds(from, 12_345)
      assert_equal 12_345, calendar.business_time_until(from, to)
      assert_equal(-12_345, calendar.business_time_until(to, from))
    end

    it "chains across a clipped night shift and a temporary opening" do
      # 3h left on the Friday night shift (21:00-24:00), then nothing until
      # the Sunday opening 10:00-12:00.
      assert_equal t(2026, 10, 11, 12, 0, 0), calendar.add_work_seconds(t(2026, 10, 9, 21), 5 * 3600)
    end
  end

  describe "integration with the existing API" do
    it "delegates Time#business_time_until" do
      from = t(2026, 10, 5, 11)
      to = t(2026, 10, 5, 14)
      assert_equal calendar.business_time_until(from, to), from.business_time_until(to, work_calendar: calendar)
    end

    it "delegates business hours addition and subtraction" do
      assert_equal t(2026, 10, 5, 14), 3.business_hours.after(t(2026, 10, 5, 10), work_calendar: calendar)
      assert_equal t(2026, 10, 5, 11), 2.business_hours.before(t(2026, 10, 5, 14), work_calendar: calendar)
    end

    it "rolls forward and backward to work time" do
      assert_equal t(2026, 10, 11, 10), Time.roll_forward(t(2026, 10, 10, 12), work_calendar: calendar)
      assert_equal t(2026, 10, 9, 17), Time.roll_backward(t(2026, 10, 9, 18), work_calendar: calendar)
      assert_equal t(2026, 10, 11, 10), 0.business_hours.after(t(2026, 10, 10, 12), work_calendar: calendar)
    end

    it "answers workday? and during_business_hours?" do
      assert_equal false, t(2026, 10, 10, 10).workday?(work_calendar: calendar)
      assert_equal true, t(2026, 10, 11, 10, 30).workday?(work_calendar: calendar)
      assert_equal true, t(2026, 10, 5, 11, 30).during_business_hours?(work_calendar: calendar)
      assert_equal false, t(2026, 10, 5, 12, 30).during_business_hours?(work_calendar: calendar)
    end

    it "keeps business days coherent with the calendar" do
      assert_equal t(2026, 10, 11, 10), 1.business_day.after(t(2026, 10, 9, 10), work_calendar: calendar)
    end
  end

  describe "DST handling" do
    let(:zone) { "America/New_York" }

    it "counts real elapsed seconds across the spring-forward gap" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sat: [["22:00", "04:00"]] },
        timezone: zone,
      )
      # 2026-03-07 22:00 EST -> 2026-03-08 04:00 EDT: 6 wall hours, 5 real hours
      from = ActiveSupport::TimeZone[zone].local(2026, 3, 7, 21)
      to = ActiveSupport::TimeZone[zone].local(2026, 3, 8, 6)
      assert_equal 5 * 3600, cal.business_time_until(from, to)
    end

    it "shifts missing local times forward by default" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sun: [["02:30", "04:00"]] },
        timezone: zone,
      )
      # 02:30 does not exist on 2026-03-08; it shifts to 03:00 EDT
      assert_equal 3600, cal.work_seconds_on(Date.new(2026, 3, 8))
    end

    it "can shift missing local times backward" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sun: [["02:30", "04:00"]] },
        timezone: zone,
        dst_gap: :shift_backward,
      )
      # 02:30 shifts back to 01:59:59 EST
      assert_equal 3601, cal.work_seconds_on(Date.new(2026, 3, 8))
    end

    it "can reject missing local times" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sun: [["02:30", "04:00"]] },
        timezone: zone,
        dst_gap: :raise,
      )
      assert_raises(ArgumentError) { cal.work_seconds_on(Date.new(2026, 3, 8)) }
    end

    it "picks the first occurrence of repeated local times by default" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sun: [["01:30", "03:00"]] },
        timezone: zone,
      )
      # 2026-11-01 01:30 EDT (first occurrence) -> 03:00 EST: 2.5 real hours
      assert_equal 2.5 * 3600, cal.work_seconds_on(Date.new(2026, 11, 1))
    end

    it "can pick the last occurrence of repeated local times" do
      cal = BusinessTime::WorkCalendar.new(
        weekly: { sun: [["01:30", "03:00"]] },
        timezone: zone,
        dst_ambiguous: :last,
      )
      # 2026-11-01 01:30 EST (second occurrence) -> 03:00 EST: 1.5 real hours
      assert_equal 1.5 * 3600, cal.work_seconds_on(Date.new(2026, 11, 1))
    end
  end
end
