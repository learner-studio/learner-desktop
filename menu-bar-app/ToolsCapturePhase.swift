import Foundation

// MARK: - tool start-capture-phase

/// Starts a new capture phase of the current experiment after a screenpipe version change.
///
/// screenpipe is the experiment's measuring instrument and updates itself (the vendor
/// forces auto-update on), so every version change is a phase boundary: analyses must not
/// pool versions. This
///   1. reads the running versions (engine from /health, app from the installed bundle),
///   2. ends the current GrowthBook phase of the experiment and starts one named for them,
///      backing the experiment up first, and only then
///   3. re-pins them in config/screenpipe-settings.json, so the preflight passes again.
/// GrowthBook goes first: if the server is unreachable the pins stay put and the preflight
/// keeps flagging the change. Re-running for the same versions changes nothing.
enum CapturePhase {
    static let experiment = "exp_speech_coach_settings_v1"
    static let log = Log("Tools:capture-phase")

    struct Options {
        var healthURL = "http://localhost:3030/health"
        var appPlist = "/Applications/screenpipe.app/Contents/Info.plist"
        var config: String
        var remote = OVHRemote()
        var dryRun = false
        var today = Date()
    }

    static func main(_ args: [String], io: ToolIO) throws -> Int32 {
        if args.contains("-h") || args.contains("--help") {
            io.out("usage: learner-desktop tool start-capture-phase [--dry-run] [--config PATH]\n"
                   + "  Ends the current GrowthBook phase, starts one named for the running screenpipe versions,\n"
                   + "  then re-pins config/screenpipe-settings.json. --dry-run changes nothing.")
            return 0
        }
        let config = Tools.option(args, "--config")
            ?? Tools.repoRoot(from: io.cwd).map { $0 + "/config/screenpipe-settings.json" }
        guard let path = config, FileManager.default.fileExists(atPath: path) else {
            io.err("config/screenpipe-settings.json not found: run from the repository or pass --config PATH")
            return 2
        }
        var o = Options(config: path)
        o.dryRun = args.contains("--dry-run")
        if let url = io.env["SCREENPIPE_API"] { o.healthURL = url + "/health" }
        let result = try run(o)
        io.out(Tools.json(result))
        return 0
    }

    static func run(_ o: Options) throws -> [String: Any] {
        let (app, engine) = try runningVersions(healthURL: o.healthURL, appPlist: o.appPlist)
        let name = phaseName(app: app, engine: engine)
        log.info("\(o.dryRun ? "dry run: " : "")phase \(name)")
        var result: [String: Any] = ["phase": name]
        result["growthbook"] = try startGrowthBookPhase(name: name, dryRun: o.dryRun, remote: o.remote)
        result["config"] = try repin(app: app, engine: engine, dryRun: o.dryRun, configPath: o.config, today: o.today)
        return result
    }

    static func runningVersions(healthURL: String, appPlist: String) throws -> (app: String, engine: String) {
        let (status, data) = Tools.http(healthURL, timeout: 5)
        let health = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard status == 200, let engine = health?["version"] as? String, !engine.isEmpty else {
            throw ToolError("could not read the screenpipe engine version from \(healthURL) (HTTP \(status))")
        }
        guard let plist = FileManager.default.contents(atPath: appPlist),
              let info = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let app = info["CFBundleShortVersionString"] as? String, !app.isEmpty else {
            throw ToolError("could not read the screenpipe app version from \(appPlist)")
        }
        return (app, engine)
    }

    /// The same string the app stamps on every turn as metadata.capture_phase
    /// (CaptureEnvironment.capturePhase).
    static func phaseName(app: String, engine: String) -> String { "screenpipe \(app) / engine \(engine)" }

    static func phaseJS(name: String, dryRun: Bool) -> String {
        "const p=" + Tools.json(["experiment": experiment, "name": name, "dryRun": dryRun], pretty: false) + ";\n" + #"""

        const g=db.getSiblingDB("growthbook"), now=new Date();
        const e=g.experiments.findOne({id:p.experiment});
        if(!e) throw Error("experiment "+p.experiment+" not found");
        const last=e.phases[e.phases.length-1];
        if(last.name===p.name){
          print(JSON.stringify({changed:false,phase:p.name,phases:e.phases.length}));
        } else if(p.dryRun){
          print(JSON.stringify({changed:false,wouldEnd:last.name,wouldStart:p.name,phases:e.phases.length}));
        } else {
          g.codex_configuration_backups.insertOne({date:now,reason:"capture phase: "+p.name,experiment:e});
          const next={...last,dateStarted:now,name:p.name};
          delete next.dateEnded;
          const phases=e.phases.slice(0,-1).concat([{...last,dateEnded:now},next]);
          g.experiments.updateOne({id:e.id},{$set:{phases:phases,dateUpdated:now}});
          print(JSON.stringify({changed:true,ended:last.name,started:p.name,phases:phases.length}));
        }
        """#
    }

    static func startGrowthBookPhase(name: String, dryRun: Bool, remote: OVHRemote) throws -> [String: Any] {
        let out = try remote.mongo(phaseJS(name: name, dryRun: dryRun), marker: "PHASE_JS")
        let result = try OVHRemote.lastJSON(out)
        log.info("GrowthBook: \(Tools.json(result, pretty: false))")
        return result
    }

    static func repin(app: String, engine: String, dryRun: Bool, configPath: String, today: Date) throws -> [String: Any] {
        var text = try String(contentsOfFile: configPath, encoding: .utf8)
        func pinned(_ key: String) -> String? {
            guard let r = text.range(of: #""\#(key)": "([^"]*)""#, options: .regularExpression) else { return nil }
            let m = String(text[r])
            return String(m.dropFirst(key.count + 5).dropLast())
        }
        guard let oldApp = pinned("_screenpipe_app_version"), let oldEngine = pinned("_screenpipe_engine_version") else {
            throw ToolError("\(configPath) has no _screenpipe_app_version / _screenpipe_engine_version pins")
        }
        if (oldApp, oldEngine) == (app, engine) { return ["changed": false, "pinned": "\(app) / \(engine)"] }
        if !dryRun {
            func set(_ key: String, _ value: String) {
                let re = try! NSRegularExpression(pattern: #"("\#(key)": )"[^"]*""#)
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                   withTemplate: "$1\"" + NSRegularExpression.escapedTemplate(for: value) + "\"")
            }
            let day = DateFormatter()
            day.dateFormat = "yyyy-MM-dd"
            day.locale = Locale(identifier: "en_US_POSIX")
            set("_screenpipe_app_version", app)
            set("_screenpipe_engine_version", engine)
            set("_captured", day.string(from: today))
            try text.write(toFile: configPath, atomically: true, encoding: .utf8)
            log.info("re-pinned \(oldApp) / \(oldEngine) -> \(app) / \(engine)")
        }
        return ["changed": !dryRun, "was": "\(oldApp) / \(oldEngine)", "now": "\(app) / \(engine)"]
    }
}
