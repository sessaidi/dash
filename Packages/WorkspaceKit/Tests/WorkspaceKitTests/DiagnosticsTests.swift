import Foundation
import Testing
@testable import WorkspaceKit

struct DiagnosticsTests {
    static let oomPod = try! JSON.parse(#"""
    {"metadata":{"name":"api-7f9c","labels":{"name":"api"}},
     "spec":{"nodeName":"gke-ws-pool-1","containers":[{"name":"api","image":"r/api:1","resources":{"requests":{"memory":"256Mi"},"limits":{"memory":"512Mi","cpu":"500m"}}}]},
     "status":{"phase":"Running","conditions":[{"type":"Ready","status":"False","reason":"ContainersNotReady"}],
       "containerStatuses":[{"name":"api","image":"r/api:1","ready":false,"restartCount":4,
         "state":{"waiting":{"reason":"CrashLoopBackOff"}},
         "lastState":{"terminated":{"reason":"OOMKilled","exitCode":137,"startedAt":"2026-11-14T10:00:00Z","finishedAt":"2026-11-14T10:05:00Z"}}}]}}
    """#)
    static let evictedPod = try! JSON.parse(#"""
    {"metadata":{"name":"worker-1","labels":{"app":"worker"}},"spec":{"nodeName":"gke-ws-pool-2","containers":[]},
     "status":{"phase":"Failed","reason":"Evicted","message":"The node was low on resource: ephemeral-storage. Container worker was using 9Gi, which exceeds its request of 0."}}
    """#)

    @Test func findsOOMKillsEvictionsAndProbeFailures() {
        let pods = [WorkspaceClient.diagnosisPod(Self.oomPod, usage: ["api-7f9c/api": ["memory": "498Mi"]]),
                    WorkspaceClient.diagnosisPod(Self.evictedPod, usage: [:])]
        #expect(pods[0].containers[0].limits == ["memory": "512Mi", "cpu": "500m"] && pods[0].containers[0].restarts == 4)
        #expect(pods[0].failingConditions == ["Ready=False (ContainersNotReady)"])
        let event = WorkspaceClient.event(try! JSON.parse(#"{"type":"Warning","reason":"Unhealthy","message":"Readiness probe failed: HTTP probe failed with statuscode: 503","involvedObject":{"kind":"Pod","name":"api-7f9c"},"count":12,"lastTimestamp":"2026-11-14T10:06:00Z"}"#))
        let findings = WorkspaceClient.findings(pods: pods, events: [event], nodes: [.init(name: "gke-ws-pool-2", pressures: ["DiskPressure"], allocatable: [:])])
        #expect(findings.map(\.title) == [
            "Killed for using too much memory (OOMKilled)", "Waiting: CrashLoopBackOff", "Pod evicted: node low on ephemeral-storage",
            "Unhealthy ×12", "Node under pressure: DiskPressure",
        ])
        #expect(findings[0].reference == "pod/api-7f9c container/api")
        #expect(findings[0].evidence.contains("memory limit=512Mi") && findings[0].evidence.contains("usage now=498Mi"))
        #expect(findings[2].evidence.hasPrefix("The node was low on resource: ephemeral-storage"))
        #expect(findings[3].evidence == "Readiness probe failed: HTTP probe failed with statuscode: 503")
    }
}

struct TraceTests {
    @Test func replaysRequestsExactlyAndFamiliarly() {
        let logs = RequestTrace(method: "GET", path: "/api/v1/namespaces/laf-12/pods/api-1/log?container=api&previous=true&tailLines=500&timestamps=true",
                                contentType: nil, body: nil, status: 200, context: "gke_fubotv-dev_us-east4-b_api-cluster-east4")
        #expect(logs.exact == "kubectl --context gke_fubotv-dev_us-east4-b_api-cluster-east4 get --raw '/api/v1/namespaces/laf-12/pods/api-1/log?container=api&previous=true&tailLines=500&timestamps=true'")
        #expect(logs.familiar == "kubectl --context gke_fubotv-dev_us-east4-b_api-cluster-east4 logs -n laf-12 api-1 -c api --tail=500 --previous --timestamps")
        let patch = RequestTrace(method: "PATCH", path: "/apis/apps/v1/namespaces/laf-12/deployments/api", contentType: "application/strategic-merge-patch+json",
                                 body: #"{"spec":{}}"#, status: 200, context: "ctx")
        #expect(patch.exact.contains("curl -s -X PATCH 'http://127.0.0.1:8001/apis/apps/v1/namespaces/laf-12/deployments/api'"))
        #expect(patch.familiar == #"kubectl --context ctx patch deployments api -n laf-12 --type strategic -p '{"spec":{}}'"#)
        let events = RequestTrace(method: "GET", path: "/api/v1/namespaces/laf-12/events", contentType: nil, body: nil, status: 200, context: "ctx")
        #expect(events.familiar == "kubectl --context ctx get events -n laf-12 -o json")
        let recorder = RequestRecorder()
        recorder.record(logs)
        recorder.record(RequestTrace(method: "GET", path: "/api/v1/namespaces/other/pods", contentType: nil, body: nil, status: 200, context: "ctx"))
        #expect(recorder.traces(namespace: "laf-12").map(\.path) == [logs.path])
    }
}
