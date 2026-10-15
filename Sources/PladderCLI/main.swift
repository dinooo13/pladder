import Foundation
import PladderCore

// Developer tool. Commands and flags: docs/ARCHITECTURE.md, "pladder-cli". Each
// command lives in a file of its own; shared helpers are in Support.swift.

func usage() -> Never {
    eprint("""
    usage: pladder-cli <audio file> [--process] [--verbose]
           pladder-cli bench <fixtures dir> [--runs N] [--pause S]
           pladder-cli bench <fixtures dir> --paced [--runs N] [--pause S] [--all] [--live]
           pladder-cli bench-process <fixtures dir> [--runs N]
           pladder-cli polish <text file | -> [--model \(PolishModel.cliNames) | --gguf <file>] [--control <line>] [--instructions <file>]
           pladder-cli polish-set <set.json> [--model \(PolishModel.cliNames) | --gguf <file>] [--control <line>]
    """)
    exit(2)
}

// MARK: - Entry

var arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil, "-h", "--help":
    usage()
case "bench":
    arguments.removeFirst()
    var runs = 6
    var pause = 10.0
    var paced = false
    var includeShort = false
    var live = false
    var dir: String?
    while let arg = arguments.first {
        arguments.removeFirst()
        if arg == "--runs" {
            guard let value = arguments.first, let n = Int(value) else { usage() }
            arguments.removeFirst()
            runs = n
        } else if arg == "--pause" {
            guard let value = arguments.first, let s = Double(value) else { usage() }
            arguments.removeFirst()
            pause = s
        } else if arg == "--paced" {
            paced = true
        } else if arg == "--all" {
            includeShort = true
        } else if arg == "--live" {
            live = true
        } else if dir == nil {
            dir = arg
        } else {
            usage()
        }
    }
    guard let dir else { usage() }
    if paced {
        try await runPacedBench(dir: dir, runs: runs, pause: pause, includeShort: includeShort, live: live)
    } else {
        // Both flags only mean something while audio is being paced in.
        if includeShort || live { usage() }
        try await runBench(dir: dir, runs: runs, pause: pause)
    }
case "bench-process":
    arguments.removeFirst()
    ProcessorBench.run(arguments: arguments)
case "polish", "polish-set":
    let command = arguments.removeFirst()
    var options = PolishOptions()
    var model = PolishModel.appleIntelligence
    var textPath: String?
    while let arg = arguments.first {
        arguments.removeFirst()
        if arg == "--instructions", command == "polish" {
            guard let value = arguments.first else { usage() }
            arguments.removeFirst()
            options.instructionsPath = value
        } else if arg == "--gguf" || arg == "--control" {
            guard let value = arguments.first else { usage() }
            arguments.removeFirst()
            if arg == "--gguf" { options.gguf = value } else { options.control = value }
        } else if arg == "--model" {
            guard let value = arguments.first, let chosen = PolishModel(cliName: value) else { usage() }
            arguments.removeFirst()
            model = chosen
        } else if textPath == nil {
            textPath = arg
        } else {
            usage()
        }
    }
    guard let textPath else { usage() }
    if command == "polish" {
        try await runPolish(textPath, model: model, options: options)
    } else {
        try await runPolishSet(textPath, model: model, options: options)
    }
default:
    var process = false
    var verbose = false
    var path: String?
    for arg in arguments {
        if arg == "--process" {
            process = true
        } else if arg == "--verbose" {
            verbose = true
        } else if path == nil {
            path = arg
        } else {
            usage()
        }
    }
    guard let path else { usage() }
    await transcribeFile(path, process: process, verbose: verbose)
}
