#!/usr/bin/env python3
"""Start a new capture phase of the current experiment after a screenpipe version change.

screenpipe is the experiment's measuring instrument and updates itself (the vendor forces
auto-update on), so every version change is a phase boundary: analyses must not pool
versions. This
  1. reads the running versions (engine from /health, app from the installed bundle),
  2. ends the current GrowthBook phase of the experiment and starts one named for them,
     backing the experiment up first, and only then
  3. re-pins them in config/screenpipe-settings.json, so the preflight passes again.
GrowthBook goes first: if the server is unreachable the pins stay put and the preflight
keeps flagging the change. Re-running for the same versions changes nothing.

Usage:
  python3 scripts/start-capture-phase.py --dry-run
  python3 scripts/start-capture-phase.py
"""
import argparse, json, plistlib, re, shlex, subprocess, sys, urllib.request
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
CONFIG = REPO / "config" / "screenpipe-settings.json"
EXPERIMENT = "exp_speech_coach_settings_v1"
APP_PLIST = Path("/Applications/screenpipe.app/Contents/Info.plist")



def ssh_script(script):
    """Run a bash script on the OVH box over the `ovh` ssh alias; return its stdout."""
    result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "ovh", "bash", "-s"],
                            input=script, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise SystemExit(f"ssh to ovh failed: {result.stderr[-2000:]}")
    return result.stdout.strip()


def running_versions():
    with urllib.request.urlopen("http://localhost:3030/health", timeout=5) as resp:
        engine = json.load(resp).get("version")
    with APP_PLIST.open("rb") as fh:
        app = plistlib.load(fh)["CFBundleShortVersionString"]
    if not engine or not app:
        sys.exit(f"could not read screenpipe versions (app={app!r}, engine={engine!r})")
    return app, engine


def phase_name(app, engine):
    # Learner Desktop stamps the same string on every turn as metadata.capture_phase.
    return f"screenpipe {app} / engine {engine}"


def mongo(js):
    command = ('exec mongosh --quiet --username "$MONGO_INITDB_ROOT_USERNAME" '
               '--password "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$(cat)"')
    return ssh_script("set -e\ndocker exec -i biztools-growthbook-growthbook-mongo-1 sh -c "
                        + shlex.quote(command) + " <<'PHASE_JS'\n" + js + "\nPHASE_JS\n")


def start_growthbook_phase(name, dry_run):
    js = "const p=" + json.dumps({"experiment": EXPERIMENT, "name": name, "dryRun": dry_run}) + ";\n" + """
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
}"""
    return json.loads(mongo(js).splitlines()[-1])


def repin(app, engine, dry_run):
    text = CONFIG.read_text()
    pinned = (re.search(r'"_screenpipe_app_version": "([^"]*)"', text).group(1),
              re.search(r'"_screenpipe_engine_version": "([^"]*)"', text).group(1))
    if pinned == (app, engine):
        return {"changed": False, "pinned": f"{app} / {engine}"}
    if not dry_run:
        text = re.sub(r'("_screenpipe_app_version": )"[^"]*"', rf'\g<1>"{app}"', text)
        text = re.sub(r'("_screenpipe_engine_version": )"[^"]*"', rf'\g<1>"{engine}"', text)
        text = re.sub(r'("_captured": )"[^"]*"', rf'\g<1>"{date.today().isoformat()}"', text)
        CONFIG.write_text(text)
    return {"changed": not dry_run, "was": f"{pinned[0]} / {pinned[1]}", "now": f"{app} / {engine}"}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="show what would change, change nothing")
    args = ap.parse_args()
    app, engine = running_versions()
    name = phase_name(app, engine)
    result = {"phase": name, "growthbook": start_growthbook_phase(name, args.dry_run)}
    result["config"] = repin(app, engine, args.dry_run)
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
