//
//  AgentObservation.swift
//  ModelCraft
//
//  Created by Hongshen on 28/1/26.
//


struct AgentObservation: Codable {
    let tool: ToolCallName
    let status: ObservationStatus
    let summary: String
    let data: ObservationData?
    let error: ToolError?
    let retryable: Bool
}

enum ObservationStatus: String, Codable {
    case success
    case empty
    case fail
}

struct ToolError: Codable {
    let type: String
    let message: String
}

enum ObservationData: Codable {
    case text(String)
    case count(Int)
    case keyValue([String: String])
    case commandOutput(stdout: String, stderr: String)
}


struct ObservationSummaryBuilder {

    static func makeSummary(
        tool: ToolCallName,
        status: ObservationStatus,
        data: ObservationData?,
        error: ToolError?
    ) -> String {

        switch status {

        case .fail:
            return error?.type.replacingOccurrences(of: "_", with: " ")
                ?? "Tool failed"

        case .empty:
            return emptySummary(for: tool)

        case .success:
            return successSummary(for: tool, data: data)
        }
    }

    // MARK: - Empty

    private static func emptySummary(for tool: ToolCallName) -> String {
        switch tool {
        case .searchMap:
            return "No results found"
        default:
            return "No output"
        }
    }

    // MARK: - Success

    private static func successSummary(
        for tool: ToolCallName,
        data: ObservationData?
    ) -> String {

        guard let data else {
            return "Operation completed successfully"
        }

        switch data {

        case .count(let count):
            return "Found \(count) items"

        case .keyValue(let dict):
            if let top = dict.first {
                return "\(top.key): \(top.value)"
            }
            return "Received structured data"

        case .commandOutput(_, let stderr):
            if !stderr.isEmpty {
                return "Command completed with warnings"
            }
            return "Command executed successfully"

        case .text:
            return "Operation completed successfully"
        }
    }
}

extension AgentObservation {

    static func build(
        tool: ToolCallName,
        status: ObservationStatus,
        data: ObservationData? = nil,
        error: ToolError? = nil,
        retryable: Bool
    ) -> AgentObservation {

        let summary = ObservationSummaryBuilder.makeSummary(
            tool: tool,
            status: status,
            data: data,
            error: error
        )

        return AgentObservation(
            tool: tool,
            status: status,
            summary: summary,
            data: data,
            error: error,
            retryable: retryable
        )
    }
}
