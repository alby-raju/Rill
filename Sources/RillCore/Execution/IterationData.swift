import Foundation

public enum IterationDataError: Error { case invalid, limit }

/// Bounded string-variable rows. JSON numbers retain their spelling without binary rounding.
public struct IterationData: Sendable {
    public enum Format: String, Sendable { case json, csv }
    public static let maximumBytes = 4 * 1024 * 1024
    public let rows: [[String: String]]

    public init(rows: [[String: String]]) throws {
        guard !rows.isEmpty, rows.count <= 10_000 else { throw IterationDataError.limit }
        var bytes = 0
        for row in rows {
            try Task.checkCancellation()
            guard row.keys.allSatisfy(ResponseRules.validVariable) else {
                throw IterationDataError.invalid
            }
            try WorkflowEngine.validateVariables(row)
            bytes += row.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
            guard bytes <= Self.maximumBytes else { throw IterationDataError.limit }
        }
        self.rows = rows
    }

    public init(data: Data, format: Format) throws {
        try Task.checkCancellation()
        guard data.count <= Self.maximumBytes else { throw IterationDataError.limit }
        let input = data.starts(with: [0xef, 0xbb, 0xbf]) ? Data(data.dropFirst(3)) : data
        guard String(data: input, encoding: .utf8) != nil else { throw IterationDataError.invalid }
        switch format {
        case .json:
            guard
                case .array(let values) = try JSONValueParser(input, preserveNumberSpelling: true)
                    .parse(),
                !values.isEmpty, values.count <= 10_000
            else { throw IterationDataError.invalid }
            let rows = try values.map { value -> [String: String] in
                try Task.checkCancellation()
                guard case .object(let fields) = value else { throw IterationDataError.invalid }
                var row: [String: String] = [:]
                for (key, value) in fields {
                    guard row[key.text] == nil else { throw IterationDataError.invalid }
                    row[key.text] = try ResponseJSON.text(value)
                }
                return row
            }
            try self.init(rows: rows)
        case .csv:
            try self.init(rows: Self.csv(input))
        }
    }

    func variables(at index: Int, base: [String: String], overrides: [String: String]) throws
        -> [String: String]
    {
        guard rows.indices.contains(index), overrides.keys.allSatisfy({ !$0.isEmpty }) else {
            throw IterationDataError.invalid
        }
        var values = base
        for (key, value) in rows[index] { values[key] = value }
        for (key, value) in overrides { values[key] = value }
        try WorkflowEngine.validateVariables(values)
        return values
    }

    private static func csv(_ input: Data) throws -> [[String: String]] {
        enum State { case start, plain, quoted, closed }
        let bytes = Array(input)
        var state = State.start
        var index = 0
        var field: [UInt8] = []
        var record: [String] = []
        var header: [String]?
        var rows: [[String: String]] = []
        var openRecord = false
        var cells = 0
        var retained = 0
        func finishField() throws {
            cells += 1
            guard cells <= 100_000, record.count < 1024 else { throw IterationDataError.limit }
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            state = .start
        }
        func finishRecord() throws {
            try finishField()
            if let names = header {
                guard record.count == names.count else { throw IterationDataError.invalid }
                let row = Dictionary(uniqueKeysWithValues: zip(names, record))
                try WorkflowEngine.validateVariables(row)
                retained += row.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                guard rows.count < 10_000, retained <= maximumBytes else {
                    throw IterationDataError.limit
                }
                rows.append(row)
            } else {
                guard record.allSatisfy(ResponseRules.validVariable),
                    Set(record).count == record.count
                else { throw IterationDataError.invalid }
                header = record
            }
            record.removeAll(keepingCapacity: true)
            openRecord = false
        }
        while index < bytes.count {
            if index % 4096 < 2 { try Task.checkCancellation() }
            let byte = bytes[index]
            if state == .quoted {
                if byte == 34 {
                    if index + 1 < bytes.count, bytes[index + 1] == 34 {
                        field.append(34)
                        index += 1
                    } else {
                        state = .closed
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == 44 {
                try finishField()
                openRecord = true
            } else if byte == 10 || byte == 13 {
                if byte == 13 {
                    guard index + 1 < bytes.count, bytes[index + 1] == 10 else {
                        throw IterationDataError.invalid
                    }
                    index += 1
                }
                try finishRecord()
            } else if byte == 34, state == .start {
                state = .quoted
                openRecord = true
            } else {
                guard byte != 34, state != .closed else { throw IterationDataError.invalid }
                state = .plain
                field.append(byte)
                openRecord = true
            }
            guard field.count <= 1024 * 1024 else { throw IterationDataError.limit }
            index += 1
        }
        guard state != .quoted else { throw IterationDataError.invalid }
        if openRecord { try finishRecord() }
        guard header != nil, !rows.isEmpty else { throw IterationDataError.invalid }
        return rows
    }
}
