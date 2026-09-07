import Foundation
import Testing
@testable import CodexBarLiteCore

@Test func `additional five hour quota survives a weekly only main allowance`() throws {
    // Same window layout as the reported response; all names and values are synthetic.
    let data = Data("""
    {"rate_limit":{
      "primary_window":{"used_percent":37,"limit_window_seconds":604800,"reset_at":2000000000},
      "secondary_window":null
    },"additional_rate_limits":[{
      "limit_name":"Example model",
      "metered_feature":"example_model",
      "rate_limit":{
        "primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1999500000},
        "secondary_window":{"used_percent":64,"limit_window_seconds":604800,"reset_at":2000000000}
      }
    }]}
    """.utf8)

    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.windows.map(\.duration) == [604_800])
    #expect(snapshot.menuWindow?.usedPercent == 37)
    let additional = try #require(snapshot.additionalLimits.first)
    #expect(additional.title == "Example model")
    #expect(additional.windows.map(\.title) == ["5 小时", "每周"])
    #expect(additional.windows.map(\.remainingPercent) == [88, 36])
    #expect(additional.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_999_500_000))
}

@Test func `malformed additional entries preserve valid siblings and named windows`() throws {
    let data = Data("""
    {"additional_rate_limits":[null,42,"bad",{
      "limit_name":42,"metered_feature":" example_model ",
      "rate_limit":{
        "primary_window":{"used_percent":"bad"},
        "secondary_window":{"used_percent":25,"limit_window_seconds":604800}
      }
    },{
      "limit_name":" ","metered_feature":" ",
      "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}
    },{
      "limit_name":"Broken example model","rate_limit":"bad"
    }]}
    """.utf8)

    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.additionalLimits.map(\.title) == ["example_model", "附加额度 5"])
    #expect(snapshot.additionalLimits.map { $0.windows.map(\.duration) } == [[604_800], [18000]])
    #expect(Set(snapshot.additionalLimits.map(\.id)).count == 2)
    #expect(snapshot.windows.isEmpty)
    #expect(snapshot.menuWindow == nil)
}

@Test(arguments: ["null", "{}", "42", "\"bad\"", "[null,42,{}]"])
func `unusable additional lists preserve the main quota`(additional: String) throws {
    let data = Data("""
    {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000}},
     "additional_rate_limits":\(additional)}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.windows.first?.remainingPercent == 80)
    #expect(snapshot.additionalLimits.isEmpty)
}

@Test func `additional exhaustion never replaces the main menu bar allowance`() throws {
    let data = Data("""
    {"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800}},
     "additional_rate_limits":[{
       "limit_name":"Example model",
       "rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":18000}}
     }]}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.menuWindow?.duration == 604_800)
    #expect(snapshot.menuWindow?.remainingPercent == 80)
    #expect(snapshot.additionalLimits.first?.windows.first?.remainingPercent == 0)
}

@Test func `additional windows use actual durations and reject invalid quota values`() throws {
    let data = Data("""
    {"additional_rate_limits":[{
      "limit_name":"Example model A",
      "rate_limit":{
        "primary_window":{"used_percent":130,"limit_window_seconds":604800},
        "secondary_window":{"used_percent":0,"limit_window_seconds":18000}
      }
    },{
      "limit_name":"Example model B",
      "rate_limit":{"primary_window":{"used_percent":-1,"limit_window_seconds":18000}}
    },{
      "limit_name":"Example model C",
      "rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":0}}
    }]}
    """.utf8)
    let snapshot = try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    #expect(snapshot.additionalLimits.count == 1)
    #expect(snapshot.additionalLimits.first?.windows.map(\.duration) == [18000, 604_800])
    #expect(snapshot.additionalLimits.first?.windows.map(\.remainingPercent) == [100, 0])
}

@Test func `missing main quota and unusable additional quotas remain unavailable`() {
    let data = Data("""
    {"additional_rate_limits":[{"rate_limit":{"primary_window":null}}]}
    """.utf8)
    #expect(throws: UsageFailure.noQuota) {
        try UsageSnapshot.decode(data, now: .now, expectedAccountID: nil)
    }
}
