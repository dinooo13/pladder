import Foundation
import PladderCore

// Developer tool.
//
//   pladder-cli <audio file>              load Parakeet, print the transcript and nothing else,
//                                         so a script or another program's STT hook can read
//                                         stdout. Errors go to stderr with exit status 1.
//       [--process]                       run the app's processors over it with the app's
//                                         dictionary and toggles, read from its settings file
//                                         (or PLADDER_SETTINGS_PATH), which is never written.
//       [--verbose]                       also print the load and processing times.
//   pladder-cli bench <fixtures dir>      run the benchmark (see docs/BENCHMARKS.md)
//       [--runs N]                        runs per fixture, default 6; the first is discarded.
//                                         Use 11 to settle a result near the noise line.
//       [--pause S]                       idle seconds before every run, default 10
//       [--paced]                         push fixtures in one-second chunks paced at real
//                                         time, as a live recording arrives, and time
//                                         `endUtterance` instead. Also transcribes each
//                                         fixture whole and reports whether the two texts
//                                         are identical, which is the gate on the
//                                         incremental path.
//                                         Fixtures under 13 s are skipped unless --all.
//       [--all]                           paced bench only: keep the short fixtures too.
//       [--live]                          paced bench only: run the Live Transcript style's
//                                         pass over the audio so far every 0.5 s while the
//                                         fixture is paced, as the overlay does, and report
//                                         how many there were and what they cost. The
//                                         `identical:` column then also proves the live
//                                         passes leave the release's windows alone.
//   pladder-cli bench-process <fixtures dir>
//                                         time the processor pipeline on the fixtures' text,
//                                         with a filler in every sentence and with a spoken
//                                         question mark as well (see docs/BENCHMARKS.md).
//       [--runs N]                        runs per variant, default 31; the first is discarded.
//   pladder-cli polish <text file | ->    run the polisher over a transcript: once cold,
//                                         once after prepare() and a two-second wait, the
//                                         way a real press warms it. Prints both timings.
//       [--model <name>]                  apple (default), s1-mini or s1-mini-8bit. An S1-mini
//                                         file is downloaded first if the app has not yet.
//       [--instructions <file>]           Apple only: try another system prompt before
//                                         committing it.
//       [--gguf <file>]                   instead of --model: any S1-mini-family GGUF, such as a
//                                         fine-tune being judged before it goes in the picker.
//       [--control <line>]                S1-mini only: another control line than the app's.
//   pladder-cli polish-set <set.json>     run a polish model over a test set (docs/polish-set.json)
//       [--model <name>]                  after the app's processors, warm, and print each
//                                         answer, the word error rate against the expected
//                                         text per language, exact matches and timings.
//       [--gguf <file>] [--control <line>] as for polish.
//
// Fixtures are audio files with a sibling .txt holding the spoken script, as
// produced by scripts/make-fixtures.sh.
//
// This file parses the command line and dispatches; each command lives in a
// file of its own: Transcribe.swift, Bench.swift (whole-buffer and paced),
// BenchProcess.swift and Polish.swift, with the shared helpers in Support.swift.

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
