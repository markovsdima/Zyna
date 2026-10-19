#!/usr/bin/env python3
"""Run opt-in UI acceptance on an explicitly selected, already logged-in device.

Never erases, deletes, clones or logs out of the device. Installs current Zyna
over the existing app. Uses the ordinary SDK and a copied Xcode project.
Raw logs, accessibility trees and screenshots can contain chat contents; keep
results local under .build. Offline scenarios must use pair.py / closure.py.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import time
from xml.sax.saxutils import quoteattr

from support import nonempty, run_name, reserve_run, stream_command, print_phase

ROOT = Path(__file__).resolve().parents[2]

def verify_reused_plan(args):
    pattern = 'Acceptance_iphoneos*.xctestrun' if args.platform == 'device' else 'Acceptance_iphonesimulator*.xctestrun'
    plans = list((args.derived_data / 'Build/Products').glob(pattern))
    if len(plans) != 1:
        raise ValueError('Expected exactly one built test plan; rebuild before --without-building')
    data = plistlib.loads(plans[0].read_bytes())
    values = data.get('AcceptanceUITests', {}).get('EnvironmentVariables', {})
    required = {'ZYNA_EXPECTED_SDK': args.expected_sdk, 'ZYNA_ACCEPTANCE_ROOM': args.room,
                'ZYNA_PHOTO_LABEL': args.photo_label or ''}
    if any(values.get(key, '') != value for key, value in required.items()):
        raise ValueError('Built plan has different room/SDK/photo parameters; rebuild before --without-building')

def collect_device_command(command):
    """Bound each best-effort collection step, including a stuck devicectl."""
    try:
        result = subprocess.run(command + ['--timeout', '30'], timeout=35,
                                stdout=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        print('Device evidence collection timed out; keeping the existing results', file=sys.stderr)
        return False
    if result.returncode:
        print('Device evidence collection failed; keeping the existing results', file=sys.stderr)
    return result.returncode == 0


def collect_device_logs(device, work, name, started):
    """Read only app log files changed during the run; never copy the database."""
    listing = work/f'{name}-log-files.json'
    base = ['xcrun', 'devicectl', 'device']
    domain = ['--device', device, '--domain-type', 'appGroupDataContainer',
        '--domain-identifier', 'group.com.app.zyna']
    if not collect_device_command(base + ['info', 'files'] + domain +
        ['--subdirectory', 'logs', '--no-recurse', '--json-output', str(listing)]):
        return
    destination = work/f'{name}-sdk-logs'
    destination.mkdir(exist_ok=True)
    for item in json.loads(listing.read_text()).get('result', {}).get('files', []):
        filename = item.get('name', '')
        if not filename.startswith('zyna-app.') or not filename.endswith('.log') or Path(filename).name != filename:
            continue
        modified = item.get('metadata', {}).get('lastModDate')
        if not modified or datetime.fromisoformat(modified.replace('Z', '+00:00')).timestamp() < started - 5:
            continue
        collect_device_command(base + ['copy', 'from'] + domain + ['--source', 'logs/' + filename,
            '--destination', str(destination/filename)])
def prepare(work, args):
    project = work / 'project/Zyna.xcodeproj'
    project.mkdir(parents=True, exist_ok=True)
    source = ROOT / 'Zyna.xcodeproj'
    data = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(source/'project.pbxproj')]))
    objects = data['objects']
    for obj in objects.values():
        if obj.get('isa') == 'XCLocalSwiftPackageReference':
            # Resolve the currently selected packages before moving the project.
            # Do not silently replace a diagnostic candidate with the old SDK.
            obj['relativePath'] = str((ROOT / obj['relativePath']).resolve())
    def put(n, value):
        key = f'FAACCE00000000000000{n:04X}'
        objects[key] = value
        return key
    src = put(1, dict(isa='PBXFileReference', lastKnownFileType='sourcecode.swift',
                     path=str(ROOT/'Scripts/SimulatorAcceptance/AcceptanceUITests.swift'), sourceTree='<absolute>'))
    build = put(2, dict(isa='PBXBuildFile', fileRef=src))
    sources = put(3, dict(isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=[build], runOnlyForDeploymentPostprocessing=0))
    frameworks = put(4, dict(isa='PBXFrameworksBuildPhase', buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0))
    product = put(5, dict(isa='PBXFileReference', explicitFileType='wrapper.cfbundle', path='AcceptanceUITests.xctest', sourceTree='BUILT_PRODUCTS_DIR'))
    settings = dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.app.zyna.acceptanceUITests',
        GENERATE_INFOPLIST_FILE='YES', SWIFT_VERSION='5.0', IPHONEOS_DEPLOYMENT_TARGET='17.0',
        TARGETED_DEVICE_FAMILY='1', SDKROOT='iphoneos', SUPPORTED_PLATFORMS='iphonesimulator',
        CODE_SIGN_STYLE='Automatic', CODE_SIGN_IDENTITY='-', DEVELOPMENT_TEAM='',
        TEST_TARGET_NAME='Zyna', SWIFT_OPTIMIZATION_LEVEL='-Onone')
    if args.platform == 'device':
        settings.update(SUPPORTED_PLATFORMS='iphoneos', CODE_SIGN_IDENTITY='Apple Development',
            DEVELOPMENT_TEAM=args.team)
    debug = put(6, dict(isa='XCBuildConfiguration', buildSettings=settings, name='Debug'))
    configs = put(7, dict(isa='XCConfigurationList', buildConfigurations=[debug], defaultConfigurationIsVisible=0, defaultConfigurationName='Debug'))
    dependency = put(8, dict(isa='PBXTargetDependency', target='324E19552DAD578A00CB5769'))
    target = put(9, dict(isa='PBXNativeTarget', name='AcceptanceUITests', productName='AcceptanceUITests',
        productType='com.apple.product-type.bundle.ui-testing', productReference=product,
        buildConfigurationList=configs, buildPhases=[sources,frameworks], buildRules=[], dependencies=[dependency]))
    objects[data['rootObject']]['targets'].append(target)
    objects[objects[data['rootObject']]['mainGroup']]['children'].extend([src,product])
    (project/'project.pbxproj').write_bytes(plistlib.dumps(data))
    shutil.copytree(source/'project.xcworkspace/xcshareddata', project/'project.xcworkspace/xcshareddata', dirs_exist_ok=True)
    schemes=project/'xcshareddata/xcschemes'; schemes.mkdir(parents=True, exist_ok=True)
    ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AcceptanceUITests.xctest" BlueprintName="AcceptanceUITests" ReferencedContainer="container:Zyna.xcodeproj"/>'
    values = {'ZYNA_EXPECTED_SDK': args.expected_sdk, 'ZYNA_ACCEPTANCE_ROOM': args.room}
    if args.photo_label:
        values['ZYNA_PHOTO_LABEL'] = args.photo_label
    environment = '<EnvironmentVariables>' + ''.join(
        f'<EnvironmentVariable key={quoteattr(key)} value={quoteattr(value)} isEnabled="YES"/>'
        for key, value in values.items()) + '</EnvironmentVariables>'
    (schemes/'Acceptance.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="NO">{environment}<Testables><TestableReference skipped="NO" parallelizable="NO">{ref}</TestableReference></Testables></TestAction></Scheme>''')
    for name in ['Zyna','ZynaTests','ZynaNotificationService','Packages','Carthage','Secrets']:
        path=project.parent/name
        if (ROOT/name).exists() and not path.exists(): path.symlink_to(ROOT/name, target_is_directory=True)
    return project

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, type=nonempty)
    parser.add_argument('--name', required=True, type=run_name)
    parser.add_argument('--test', default='testProbe')
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--platform', choices=['simulator', 'device'], default='simulator')
    parser.add_argument('--team', help='Development team for the isolated physical-device UI runner')
    parser.add_argument('--allow-provisioning-updates', action='store_true')
    parser.add_argument('--without-building', action='store_true')
    parser.add_argument('--build-only', action='store_true',
        help='Build app and UI runner for a generic destination; never access the device')
    parser.add_argument('--expected-sdk', required=True, type=nonempty,
        help='Expected Rust sdkGitSha(); the Swift package revision is not this identity')
    parser.add_argument('--room', required=True, type=nonempty, help='Unique room display name on this client')
    parser.add_argument('--photo-label', type=nonempty, help='Exact accessibility label of the prepared test photo')
    args=parser.parse_args()
    if args.platform == 'device' and not args.team:
        parser.error('--team is required for physical devices')
    if args.build_only and args.without_building:
        parser.error('--build-only and --without-building are mutually exclusive')
    if args.without_building:
        try:
            verify_reused_plan(args)
        except (ValueError, OSError) as error:
            parser.error(str(error))
    work = ROOT / ('.build/iphone-acceptance' if args.platform == 'device' else '.build/simulator-acceptance')
    work.mkdir(parents=True, exist_ok=True)
    try:
        reserve_run(work, args.name)
    except ValueError as error:
        parser.error(str(error))
    if args.build_only:
        pass
    elif args.platform == 'simulator':
        subprocess.run(['xcrun','simctl','get_app_container',args.device,'com.app.zyna.Zyna','data'],check=True,stdout=subprocess.DEVNULL)
    else:
        apps = work/f'{args.name}-installed.json'
        subprocess.run(['xcrun','devicectl','device','info','apps','--device',args.device,
            '--filter','bundleIdentifier == "com.app.zyna.Zyna"','--json-output',str(apps)],
            check=True,stdout=subprocess.DEVNULL)
        installed = json.loads(apps.read_text()).get('result', {}).get('apps', [])
        if not any(app.get('bundleIdentifier') == 'com.app.zyna.Zyna' for app in installed):
            parser.error('Zyna must already be installed and logged in; not installing into an empty device')
    project=prepare(work, args)
    destination = 'iOS' if args.platform == 'device' else 'iOS Simulator'
    action = 'build-for-testing' if args.build_only else ('test-without-building' if args.without_building else 'test')
    destination_spec = f'generic/platform={destination}' if args.build_only else f'platform={destination},id={args.device}'
    command=['xcodebuild',action,
        '-project',str(project),'-scheme','Acceptance','-configuration','Debug',
        '-destination',destination_spec,'-derivedDataPath',str(args.derived_data),
        '-clonedSourcePackagesDirPath',str(args.derived_data/'SourcePackages'),'-disableAutomaticPackageResolution',
        '-parallel-testing-enabled','NO','-maximum-concurrent-test-simulator-destinations','1',
        '-only-testing:AcceptanceUITests/AcceptanceUITests/'+args.test,
        '-resultBundlePath',str(work/f'{args.name}.xcresult')]
    if args.platform == 'simulator':
        command += ['CODE_SIGN_IDENTITY=-','CODE_SIGNING_ALLOWED=YES']
    if args.allow_provisioning_updates:
        command += ['-allowProvisioningUpdates']
    started = time.time()
    provenance = dict(startedEpoch=started, platform=args.platform, test=args.test,
        appGitHead=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
        trackedDiffSHA256=hashlib.sha256(subprocess.check_output(['git','diff','HEAD'],cwd=ROOT)).hexdigest(),
        testSourceSHA256=hashlib.sha256((ROOT/'Scripts/SimulatorAcceptance/AcceptanceUITests.swift').read_bytes()).hexdigest(),
        probeSourceSHA256=hashlib.sha256((ROOT/'Zyna/Debug/SimulatorAcceptanceProbe.swift').read_bytes()).hexdigest(),
        withoutBuilding=args.without_building, buildOnly=args.build_only,
        expectedSDK=args.expected_sdk, command=command)
    (work/f'{args.name}-input.json').write_text(json.dumps(provenance,indent=2)+'\n')
    print('Running:', ' '.join(command), flush=True)
    try:
        returncode = stream_command(command, work/f'{args.name}.log', print_phase)
    except KeyboardInterrupt:
        returncode = 130
    # Preserve the test outcome even if evidence collection is interrupted.
    (work/f'{args.name}-result.json').write_text(json.dumps(dict(
        returncode=returncode, collectionComplete=False, finishedEpoch=time.time()), indent=2) + '\n')
    if args.build_only:
        (work/f'{args.name}-result.json').write_text(json.dumps(dict(
            returncode=returncode, buildOnly=True, deviceRun=False,
            finishedEpoch=time.time()),indent=2)+'\n')
        print('Build result:',returncode,'Log:',work/f'{args.name}.log',flush=True)
        raise SystemExit(returncode)
    if args.platform == 'simulator':
        container=Path(subprocess.check_output(['xcrun','simctl','get_app_container',args.device,
            'com.app.zyna.Zyna','data'],text=True).strip())
        metrics=container/'Documents/simulator-acceptance.jsonl'
        if metrics.exists(): shutil.copy2(metrics,work/f'{args.name}-metrics.jsonl')
    else:
        collect_device_command(['xcrun','devicectl','device','copy','from','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier','com.app.zyna.Zyna',
            '--source','Documents/simulator-acceptance.jsonl','--destination',str(work/f'{args.name}-metrics.jsonl')])
        collect_device_logs(args.device, work, args.name, started)
    metrics_path = work/f'{args.name}-metrics.jsonl'
    summaries = {}
    if metrics_path.exists() and '[AcceptancePhase]' in (work/f'{args.name}.log').read_text(errors='replace'):
        summaries['metrics'] = subprocess.run([sys.executable, str(ROOT/'Scripts/SimulatorAcceptance/analyze.py'),
            str(work/args.name)],stdout=subprocess.DEVNULL).returncode == 0
        if (work/f'{args.name}-sdk-logs').exists():
            summaries['sdk'] = subprocess.run([sys.executable,str(ROOT/'Scripts/SimulatorAcceptance/collect_sdk.py'),
                str(work/args.name),'--logs',str(work/f'{args.name}-sdk-logs')],
                stdout=subprocess.DEVNULL).returncode == 0
    print('Result:',returncode,'Log:',work/f'{args.name}.log','Summaries:',summaries,flush=True)
    (work/f'{args.name}-result.json').write_text(json.dumps(dict(
        returncode=returncode, summaries=summaries, collectionComplete=True,
        finishedEpoch=time.time()),indent=2)+'\n')
    raise SystemExit(returncode)

if __name__=='__main__': main()
