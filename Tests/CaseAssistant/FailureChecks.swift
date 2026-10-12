import Foundation

@main
struct FailureChecks {
    @MainActor static func main() async throws {
        let rpc = CaseAssistantRPC(executableURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let assistant = CaseAssistant(rpc: rpc)
        defer { rpc.stop() }
        func run(_ scenario: String) async throws -> [String: Any] {
            let started = try await assistant.handle("caseAssistant.start", params: ["caseId": "500000000000001AAA", "caseNumber": "100001", "prompt": scenario], owner: "case-handoff")
            for _ in 0..<100 {
                let result = try await assistant.handle("caseAssistant.poll", params: ["jobId": started["jobId"]!], owner: "case-handoff")
                if result["status"] as? String != "running" { return result }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Fixture did not finish")
        }
        let denied = try await run("workspace-denied")
        precondition(denied["status"] as? String == "failed")
        precondition(denied["errorCode"] as? String == "workspace_access_denied")
        precondition(denied["httpStatus"] as? Int == 403)
        precondition((denied["progress"] as? String)?.contains("administrator") == true)
        precondition(!(denied["progress"] as! String).contains("synthetic-secret"))
        print("PASS: captured workspace denial produces an actionable message without raw provider details")
        var stopped = false
        for _ in 0..<100 {
            let stats = try await rpc.call("test/stats", [:])
            if stats["interrupted"] as? Int == 1 { stopped = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(stopped)
        let afterStop = try await assistant.handle("caseAssistant.poll", params: ["jobId": denied["jobId"]!], owner: "case-handoff")
        precondition(afterStop["errorCode"] as? String == "workspace_access_denied" && afterStop["status"] as? String == "failed")
        print("PASS: permanent denial interrupts service retries and a later cancellation cannot erase its reason")
        let status = try await assistant.handle("caseAssistant.status", params: [:], owner: "case-handoff")
        precondition(status["chatgpt"] as? Bool == true && status["slack"] as? Bool == true && status["inference"] as? String == "blocked")
        print("PASS: signed-in and Slack-connected are distinct from blocked inference access")
        let recovered = try await run("retry-success")
        precondition(recovered["status"] as? String == "completed" && recovered["research"] != nil && recovered["errorCode"] == nil)
        let ready = try await assistant.handle("caseAssistant.status", params: [:], owner: "case-handoff")
        precondition(ready["inference"] as? String == "available")
        print("PASS: a transient stream error can recover to a completed brief and clear the old failure")
        let usage = try await run("usage-limit")
        precondition(usage["status"] as? String == "failed" && usage["errorCode"] as? String == "usage_limit")
        print("PASS: terminal turn errors are handled without a preceding error notification")
        let cancelled = try await run("interrupted")
        precondition(cancelled["status"] as? String == "cancelled" && cancelled["errorCode"] == nil)
        print("PASS: interrupted turns are cancellations, not connection failures")
        do { _ = try await rpc.call("test/rpc-denied", [:]); preconditionFailure("Expected refusal") }
        catch { precondition(error.localizedDescription.contains("administrator") && !error.localizedDescription.contains("synthetic-secret")) }
        precondition(!CaseAssistantIssue.from(["message":"Bearer synthetic-secret"]).message.contains("synthetic-secret"))
        print("PASS: RPC refusals use the same safe actionable classification; unknown payloads are not exposed")
    }
}
