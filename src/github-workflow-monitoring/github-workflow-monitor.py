"""Get aggregate statistics for Scheduled Github Workflows"""

import argparse
import json
import subprocess
import datetime
import os
import textwrap
import sys

CURL_TIMEOUT_SECS = 10
API_PAGE_SIZE = 100
PIPELINE_TIMEOUT_SECS = 216000

GITHUB_REPOS = [
    "dso-certificates",
    "dso-infra-azure-ad",
    "dso-infra-azure-fixngo",
    "dso-modernisation-platform-automation",
    "dso-repositories",
    "dso-useful-stuff",
]

def run_github_api(uri, github_token):
    """Invoke curl to call API"""

    cmd = [
        'curl',
        '-s',
        '-H',
        f'Authorization: Bearer {github_token}',
        uri,
    ]
    result = subprocess.run(cmd,
                            capture_output=True,
                            text=True,
                            check=False,
                            timeout=CURL_TIMEOUT_SECS)
    if result.returncode != 0:
        raise ValueError(f'exit code {result.returncode} for {uri}' + os.linesep + result.stderr)
    return json.loads(result.stdout)


def add_workflow_stat(workflow_summary, repo, name, status):
    """Add to the workflow stats"""

    zeroed_stats = {}
    zeroed_stats["success"] = 0
    zeroed_stats["failed"] = 0
    if 'all' not in workflow_summary:
        workflow_summary['all'] = {}
        workflow_summary['all']['all'] = zeroed_stats.copy()
    if name not in workflow_summary['all']:
        workflow_summary['all'][name] = zeroed_stats.copy()
    if repo is not None:
        if repo not in workflow_summary:
            workflow_summary[repo] = {}
            workflow_summary[repo]['all'] = zeroed_stats.copy()
        if name not in workflow_summary[repo]:
            workflow_summary[repo][name] = zeroed_stats.copy()
    if status is not None:
        workflow_summary['all']['all'][status] += 1
        workflow_summary['all'][name][status] += 1
        if repo is not None:
            workflow_summary[repo]['all'][status] += 1
            workflow_summary[repo][name][status] += 1


def check_workflow_run(workflow_summary, repo, workflow_run, verbose, start_timestamp, end_timestamp):
    """Parse workflow json and add to the workflow stats"""

    path = workflow_run['path']
    filename = path.split('/')[-1].split('.')[0]
    status = workflow_run['status']
    created_at = workflow_run['created_at']
    run_number = workflow_run['run_number']

    add_workflow_stat(workflow_summary, repo, filename, None)

    if verbose >= 4:
        sys.stderr.write(
            textwrap.indent(json.dumps(workflow_run, indent=1),
                            'Verbose4: ') + os.linesep)

    if status != 'completed':
        if verbose >= 2:
            sys.stderr.write(
                f'Verbose2: {repo} {filename}#{run_number} start={created_at}: ignoring {status}'
                + os.linesep)
        return

    updated_at = workflow_run['updated_at']
    timestamp = datetime.datetime.strptime(updated_at, '%Y-%m-%dT%H:%M:%S%z')

    if timestamp < start_timestamp or timestamp >= end_timestamp:
        return

    conclusion = workflow_run['conclusion']
    if conclusion in ['failure', 'timed_out']:
        if verbose >= 1:
            sys.stderr.write(
                f'Verbose1: {repo} {filename}#{run_number} start={created_at} end={updated_at}: {conclusion}'
                + os.linesep)
        add_workflow_stat(workflow_summary, repo, filename, 'failed')
    elif conclusion in ['success']:
        if verbose >= 3:
            sys.stderr.write(
                f'Verbose3: {repo} {filename}#{run_number} start={created_at} end={updated_at}: {conclusion}'
                + os.linesep)
        add_workflow_stat(workflow_summary, repo, filename, 'success')
    else:
        if verbose >= 2:
            sys.stderr.write(
                f'Verbose2: {repo} {filename}#{run_number} start={created_at} end={updated_at}: ignoring {conclusion}'
                + os.linesep)


def print_workflow_summary_csv(workflow_summary, timestamp):
    """print ssm workflow stats in csv"""

    print('Timestamp,Repo,WorkflowName,SuccessCount,FailedCount')
    for repo in workflow_summary.keys():
        for name in workflow_summary[repo].keys():
            workflow = workflow_summary[repo][name]
            print(
                f'{timestamp},{repo},{name},{workflow["success"]},{workflow["failed"]}'
            )


def main():
    """Main function"""

    parser = argparse.ArgumentParser(
        description='Check Github Scheduled Workflow status')
    parser.add_argument('-i',
                        '--interval',
                        required=True,
                        type=int,
                        help='Check SSM workflow for this time interval in seconds')
    parser.add_argument('-n',
                        '--number',
                        type=int,
                        default=1,
                        help='How many intervals to check back for')
    parser.add_argument('-r',
                        '--round',
                        action='store_true',
                        help='Round the time interval checked, e.g. if 3600, check from 14:00 to 15:00')
    parser.add_argument('-v',
                        '--verbose',
                        action='count',
                        default=0,
                        help='Verbose output')
    parser.add_argument('repo',
                        nargs='+',
                        help='1 or more repo names. Set to all to use defaults from script')

    args = parser.parse_args()

    timestamp = datetime.datetime.now(datetime.timezone.utc)
    timestamp = timestamp.replace(microsecond=0)
    if args.round:
        epoch_time = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
        delta = int((timestamp - epoch_time).total_seconds()) % args.interval
        end_timestamp = timestamp - datetime.timedelta(seconds=delta)
        start_timestamp = end_timestamp - datetime.timedelta(seconds=args.interval*args.number)
    else:
        start_timestamp = timestamp - datetime.timedelta(seconds=args.interval*args.number)
        end_timestamp = timestamp
    created_after_timestamp = start_timestamp - datetime.timedelta(seconds=PIPELINE_TIMEOUT_SECS)
    one_day_ago_timestamp = timestamp - datetime.timedelta(days=1)
    created_after_timestamp = min(one_day_ago_timestamp, created_after_timestamp)

    if os.environ.get('GITHUB_TOKEN') is None:
        raise ValueError('please set GITHUB_TOKEN environment variable')
    github_token = os.environ.get('GITHUB_TOKEN')

    workflow_summary = {}
    repos = args.repo
    if repos is None or repos[0] == 'all':
        repos = GITHUB_REPOS

    for repo in repos:
        date = created_after_timestamp.strftime("%Y-%m-%dT%TZ")
        num_workflows_processed = 0
        for page in range(1,10000):
            uri = f'https://api.github.com/repos/ministryofjustice/{repo}/actions/runs?event=schedule&created=>={date}&per_page={API_PAGE_SIZE}&page={page}'
            if args.verbose >= 4:
                sys.stderr.write(f'Verbose4: {uri}{os.linesep}')
            workflow_runs = run_github_api(uri, github_token)

            if 'workflow_runs' not in workflow_runs or 'total_count' not in workflow_runs:
                sys.stderr.write(json.dumps(workflow_runs, indent=1))
                raise ValueError('API response error')

            total_count = workflow_runs["total_count"]
            num_workflows = len(workflow_runs['workflow_runs'])
            num_workflows_processed += num_workflows
            if args.verbose >= 4:
                sys.stderr.write(f'Verbose4: page {page}: got {num_workflows} workflows; {num_workflows_processed}/{total_count}{os.linesep}')

            for workflow_run in workflow_runs['workflow_runs']:
                check_workflow_run(workflow_summary, repo, workflow_run, args.verbose, start_timestamp, end_timestamp)
            if num_workflows_processed == total_count:
                break
            if num_workflows == 0:
                sys.stderr.write(f'page {page}: {num_workflows_processed}/{total_count}{os.linesep}')
                raise ValueError(f'API did not return all workflow page={page} processed={num_workflows_processed}/{total_count}')

    csv_timestamp = end_timestamp
    print_workflow_summary_csv(workflow_summary, csv_timestamp.strftime("%Y-%m-%dT%TZ"))


main()
