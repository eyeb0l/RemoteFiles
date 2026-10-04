#!/usr/bin/env python3
"""Exact-source, Simulator-only staged verification with owned-state cleanup."""
import datetime
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
import argparse
parser = argparse.ArgumentParser(description="Signed disposable Simulator image reading-anchor regressions")
parser.add_argument('--output', required=True, type=Path)
parser.add_argument('--derived-data', required=True, type=Path)
parser.add_argument('--packages', required=True, type=Path)
options = parser.parse_args()
REPO = Path(__file__).resolve().parent.parent
OUT = options.output.resolve()
EXPECTED = subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip()
canonical = subprocess.check_output(['git','rev-parse','--git-common-dir'],cwd=REPO,text=True).strip()
canonical = (REPO/canonical).resolve().parent
canonical_before = subprocess.check_output(['git','status','--porcelain=v1','--untracked-files=all'],cwd=canonical,text=True)
canonical_head = subprocess.check_output(['git','rev-parse','HEAD'],cwd=canonical,text=True).strip()
spec = importlib.util.spec_from_file_location('acceptance', REPO/'scripts/test-acceptance.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
OUT.mkdir(parents=True)
ROOT, metadata = a.snapshot(REPO, OUT, True)
assert metadata['commit'] == EXPECTED
ENV = dict(os.environ)
for key in list(ENV):
    if key.startswith(('REMOTEFILES_REAL_', 'TEST_RUNNER_REMOTEFILES_REAL_')): del ENV[key]
ENV.update(REMOTEFILES_REAL_SERVER='0',TEST_RUNNER_REMOTEFILES_REAL_SERVER='0',REMOTEFILES_TEST_PORT='22388',REMOTEFILES_SOURCE_PACKAGES_DIR=str(OUT/'SourcePackages'),NSUnbufferedIO='YES')
report = {'source':metadata,'lanes':[],'simulator':None,'voiceover_original':None,'cleanup':{},'status':'running'}
sim = None
current = None

def save(): (OUT/'summary.json').write_text(json.dumps(report,indent=2)+'\n')

def command(name,args,total=60,startup=None,monitor=None,env=None):
    global current
    path = OUT/(name+'.log')
    watch = Path(monitor) if monitor else path
    began=time.monotonic(); first=None; last_progress=began; last_size=-1; methods=0; seen_size=-1; last_method=began; reason=None
    print('START '+name,flush=True)
    with path.open('w') as f:
        current=subprocess.Popen([str(x) for x in args],cwd=ROOT,env=env or ENV,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
        p=current
        try:
            while p.poll() is None:
                now=time.monotonic()
                size=watch.stat().st_size if watch.exists() else 0
                if size!=last_size: last_progress=now;last_size=size
                if startup is not None and size!=seen_size:
                    text=watch.read_text(errors='replace') if watch.exists() else ''
                    count=len(re.findall(r"Test Case '-\[.*?\]' started",text))
                    if count>methods:
                        if first is None: first=now
                        last_method=now;methods=count
                        print(name+' METHODS_STARTED='+str(methods),flush=True)
                    seen_size=size
                if now-began>total: reason='total deadline '+str(total)+'s'
                elif startup is not None and first is None and now-began>startup: reason='first-method startup deadline '+str(startup)+'s'
                elif startup is not None and first is not None and now-first>1200: reason='execution deadline 1200s'
                elif startup is not None and first is not None and now-last_method>300: reason='method progress deadline 300s'
                elif startup is None and total>=300 and now-last_progress>300: reason='log idle deadline 300s'
                if reason:
                    for sig,limit in [(signal.SIGINT,20),(signal.SIGTERM,10),(signal.SIGKILL,5)]:
                        try:os.killpg(p.pid,sig)
                        except ProcessLookupError:break
                        try:p.wait(timeout=limit);break
                        except subprocess.TimeoutExpired:continue
                    break
                time.sleep(1)
            p.wait(timeout=5)
        except BaseException:
            try:os.killpg(p.pid,signal.SIGINT);p.wait(timeout=20)
            except (ProcessLookupError,subprocess.TimeoutExpired):
                try:os.killpg(p.pid,signal.SIGKILL);p.wait(timeout=5)
                except ProcessLookupError:pass
            raise
        finally:current=None
    lane={'name':name,'command':[str(x) for x in args],'log':str(watch),'launcher_log':str(path),'exit_code':p.returncode,'seconds':round(time.monotonic()-began,3),'deadline':reason,'methods_started':methods,'status':'passed' if p.returncode==0 and not reason else 'blocked' if reason else 'failed'}
    report['lanes'].append(lane);save();print('DONE '+name+' '+json.dumps(lane),flush=True)
    return lane

def require(lane):
    if lane['status']!='passed':raise RuntimeError(lane['name']+': '+str(lane['deadline'] or 'exit '+str(lane['exit_code'])))

def test_result(lane,expected,skips=(),result=None):
    results=a.log_tests(Path(lane['log']));lane['tests']=results
    lane['counts']={key:sum(v==key for v in results.values()) for key in ['passed','failed','skipped']}
    lane['expected_test_count']=len(expected);lane['not_run']=sorted(set(expected)-results.keys())
    lane['extra']=sorted(results.keys()-set(expected))
    lane['unexpected_skips']=sorted(k for k,v in results.items() if v=='skipped' and k not in skips)
    if result and result.exists():
        lane['xcresult']=str(result)
        for kind in ['summary','tests']:
            extraction=command(lane['name']+'-xcresult-'+kind,['xcrun','xcresulttool','get','test-results',kind,'--path',result],total=45)
            if extraction['status']=='passed' and kind=='summary':
                summary=json.loads(Path(extraction['log']).read_text());lane['xcresult_counts']={k:summary[k] for k in ['passedTests','failedTests','skippedTests','expectedFailures']}
                assert (summary['passedTests'],summary['failedTests'],summary['skippedTests'])==tuple(lane['counts'][x] for x in ['passed','failed','skipped'])
                assert summary['expectedFailures']==0
    if lane['not_run'] or lane['extra'] or lane['unexpected_skips'] or lane['counts']['failed']:lane['status']='blocked' if lane['deadline'] else 'failed'
    save();print('COUNTS '+lane['name']+' '+json.dumps(lane['counts'])+' NOT_RUN='+str(len(lane['not_run'])),flush=True)

def base_tests(xctestrun,result):
    return ['xcodebuild','-jobs','2','-xctestrun',xctestrun,'-destination','platform=iOS Simulator,id='+sim,'-destination-timeout','45','-resultBundlePath',result,'-parallel-testing-enabled','NO','-collect-test-diagnostics','never','-test-timeouts-enabled','YES','-default-test-execution-time-allowance','180','-maximum-test-execution-time-allowance','240']


try:
    require(command('first-launch',['xcodebuild','-checkFirstLaunchStatus']))
    (OUT/'SourcePackages').symlink_to(options.packages.resolve(),target_is_directory=True)
    created=command('create-owned-simulator',['xcrun','simctl','create','RemoteFiles initial render image anchor diagnostic','com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro','com.apple.CoreSimulator.SimRuntime.iOS-27-0'])
    require(created);sim=Path(created['log']).read_text().strip();assert re.fullmatch('[A-F0-9-]{36}',sim),sim
    report['simulator']={'udid':sim,'owned':True,'original_state':'new disposable device; Shutdown'};save()
    require(command('boot-owned-simulator',['xcrun','simctl','boot',sim],total=45))
    require(command('boot-readiness',['xcrun','simctl','bootstatus',sim,'-b'],total=120))
    derived=options.derived_data.resolve();packages=OUT/'SourcePackages'
    build=['xcodebuild','-jobs','2','-project','RemoteFiles.xcodeproj','-scheme','RemoteFiles','-configuration','Debug','-destination','platform=iOS Simulator,id='+sim,'-destination-timeout','45','-derivedDataPath',derived,'-clonedSourcePackagesDirPath',packages,'-onlyUsePackageVersionsFromResolvedFile','CODE_SIGNING_ALLOWED=YES','CODE_SIGN_IDENTITY=-','build-for-testing']
    private_project=OUT/'fixture-project/RemoteFiles.xcodeproj'
    shutil.copytree(ROOT/'RemoteFiles.xcodeproj',private_project)
    pbx=private_project/'project.pbxproj'
    code=pbx.read_text().replace('relativePath = .;', 'relativePath = '+json.dumps(str(ROOT))+';')
    def replace_path(match):
        rel=match[1].strip('"')
        if rel.endswith('.swift'):
            path=ROOT/'Tests/ReadingAnchorFixtures/RemoteFilesReadingAnchorApp.swift' if rel=='App/RemoteFilesApp.swift' else ROOT/'Tests/ReadingAnchorFixtures/RemoteFilesReadingAnchorTests.swift' if rel=='Tests/RemoteFilesUITests/RemoteFilesUITests.swift' else ROOT/rel
            return 'path = '+json.dumps(str(path))+'; sourceTree = SOURCE_ROOT;'
        return match[0]
    pbx.write_text(re.sub(r'path = ("[^\"]+"|[^;]+); sourceTree = SOURCE_ROOT;',replace_path,code))
    build[build.index('-project')+1]=str(private_project)
    require(command('build-for-testing',build,total=1200))
    files=list((derived/'Build/Products').glob('*iphonesimulator*.xctestrun'));assert len(files)==1,files
    xctestrun=files[0]
    focused=command('image-anchor',base_tests(xctestrun,OUT/'image-anchor.xcresult')+['-only-testing:RemoteFilesUITests/ReadingAnchorUITests','test-without-building'],total=900,startup=600)
    test_result(focused,a.expected_tests(ROOT,'iOS',['Tests/ReadingAnchorFixtures']),result=OUT/'image-anchor.xcresult');require(focused)
    report['status']='passed'
except BaseException as error:
    report['status']='blocked' if any(x['status']=='blocked' for x in report['lanes']) else 'failed'
    report['blocker']=str(error);print('BLOCKER '+str(error),flush=True)
finally:
    if sim:
        shutdown=command('shutdown-owned-simulator',['xcrun','simctl','shutdown',sim],total=45)
        deleted=command('delete-owned-simulator',['xcrun','simctl','delete',sim],total=45)
        report['cleanup']['owned_simulator_deleted']=deleted['status']=='passed'
    frozen=json.loads((OUT/'source-manifest.json').read_text())
    report['cleanup']['frozen_source_unchanged']=a.manifest(ROOT,[x['path'] for x in frozen])==frozen
    report['cleanup']['isolated_source_unchanged']=a.manifest(REPO,a.source_files(REPO))==frozen and a.capture(['git','rev-parse','HEAD'],REPO)==EXPECTED
    report['cleanup']['canonical_head_unchanged']=a.capture(['git','rev-parse','HEAD'],canonical)==canonical_head
    report['cleanup']['canonical_status_unchanged']=subprocess.check_output(['git','status','--porcelain=v1','--untracked-files=all'],cwd=canonical,text=True)==canonical_before
    report['finished_utc']=datetime.datetime.now(datetime.timezone.utc).isoformat();save()
    print('TERMINAL '+str(OUT/'summary.json'),flush=True)
