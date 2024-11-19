"""Get aggregate statistics for SSM Command Invocation"""

import argparse
import json
import subprocess
import datetime
import os
import textwrap
import sys

AWSCLI_TIMEOUT_SECS = 30
AWSCLI_COMMON_ARGS = []

IGNORE_FAILURES_WITHOUT_ASSOCIATION = {
    "AWS-UpdateSSMAgent",
    "AmazonInspector2-ConfigureInspectorSsmPlugin",
    "AmazonInspector2-ConfigureInspectorSsmPluginLinux",
    "AmazonInspector2-InvokeInspectorSsmPlugin",
    "AmazonInspector2-InvokeInspectorSsmPluginLinux",
    "ec2-configuration-management-windows",
    "ec2-configuration-management-linux"
}

IGNORE_FAILURES_BY_TAGS = {
    # This seems to fail when windows server comes back up
    "AmazonInspector2-InvokeInspectorSsmPlugin": [
        { "os-type": "Linux" },
        { "environment-name": "nomis-development", "server-type": "NomisClient" },
        { "environment-name": "nomis-preproduction", "server-type": "NomisClient"},
        { "server-type": "NartClient" },  # doesn't support windows 2012
    ],
    "AmazonInspector2-InvokeInspectorSsmPluginLinux": [
        { "os-type": "Windows" },
        { "server-type": "nomis-web" },  # doesn't support RHEL6
        { "server-type": "onr-boe" },  # doesn't support RHEL6
        { "server-type": "onr-web" },  # doesn't support RHEL6
    ],
    "AmazonInspector2-ConfigureInspectorSsmPlugin": [
        { "os-type": "Linux" },
        { "server-type": "NartClient" },  # doesn't support windows 2012
    ],
    "AmazonInspector2-ConfigureInspectorSsmPluginLinux": [
        { "os-type": "Windows" },
        { "server-type": "nomis-web" },  # doesn't support RHEL6
        { "server-type": "onr-boe" },  # doesn't support RHEL6
        { "server-type": "onr-web" },  # doesn't support RHEL6
    ],
    "AWSEC2-CreateVssSnapshot": [
        { "application": "corporate-staff-rostering" },  # fix the backup policy
        { "application": "nomis-data-hub" },
        { "application": "oasys-national-reporting" },
        { "application": "Oasys National Reporting/ONR" },
        { "application": "planetfm"  },
    ],
}


def run_aws_cli(cmd):
    """Invoke AWS CLI and raise exception on error"""

    cmd += AWSCLI_COMMON_ARGS
    result = subprocess.run(cmd,
                            capture_output=True,
                            text=True,
                            check=False,
                            timeout=AWSCLI_TIMEOUT_SECS)
    if result.returncode != 0:
        raise ValueError(f'exit code {result.returncode} for cmd' +
                         ' '.join(cmd) + os.linesep + result.stderr)
    return json.loads(result.stdout)


def describe_tags():
    """Get EC2 Instance tags"""

    cmd = [
        'aws',
        'ec2',
        'describe-tags',
        '--filters',
        'Name=resource-type,Values=instance'
    ]
    return run_aws_cli(cmd)


def list_associations():
    """Get SSM Doc associations"""

    cmd = [
        'aws',
        'ssm',
        'list-associations',
    ]
    return run_aws_cli(cmd)


def list_commands(timestamp):
    """Get SSM Command history"""

    cmd = [
        'aws',
        'ssm',
        'list-commands',
        '--filters',
        'key=InvokedAfter,value=' + timestamp.strftime("%Y-%m-%dT%TZ"),
    ]
    return run_aws_cli(cmd)


def list_command_invocations(timestamp):
    """Get SSM Command Invocation history"""

    cmd = [
        'aws',
        'ssm',
        'list-command-invocations',
        '--filters',
        'key=InvokedAfter,value=' + timestamp.strftime("%Y-%m-%dT%TZ"),
    ]
    return run_aws_cli(cmd)


def tags_json_to_instance_dict(tags_json):
    """Convert AWS EC2 instance tags json into more convenient dictionary"""

    instance_dict = {}
    for tag in tags_json['Tags']:
        instance_id = tag['ResourceId']
        tag_key = tag['Key']
        tag_value = tag['Value']
        if instance_id not in instance_dict:
            instance_dict[instance_id] = {}
        instance_dict[instance_id][tag_key] = tag_value
    return instance_dict


def associations_json_to_associations_dict(associations_json):
    """Convert SSM doc association json into more convenient dictionary"""

    associations_dict = {}
    for association in associations_json['Associations']:
        association_id = association['AssociationId']
        associations_dict[association_id] = association
    return associations_dict


def is_taglist_match(instance_tags, match_tags):
    """Check if an instance has the given tag values"""

    for match_tag in match_tags.keys():
        if match_tag not in instance_tags.keys():
            return False
        if instance_tags[match_tag] != match_tags[match_tag]:
            return False
    return True


def is_status_ignorable(document_name, status, instance_tags):
    """Check whether to skip over a failed SSM doc as defined in global variables"""

    if document_name not in IGNORE_FAILURES_BY_TAGS:
        return False
    if status != 'Failed':
        return False
    for tag_list in IGNORE_FAILURES_BY_TAGS[document_name]:
        if is_taglist_match(instance_tags, tag_list):
            return True
    return False


def add_commands_stat(commands_summary, instance_id, document_name, status):
    """Add to the SSM command stats"""

    zeroed_stats = {}
    zeroed_stats["ignore"] = 0
    zeroed_stats["success"] = 0
    zeroed_stats["failed"] = 0
    if 'all' not in commands_summary:
        commands_summary['all'] = {}
        commands_summary['all']['all'] = zeroed_stats.copy()
    if document_name not in commands_summary['all']:
        commands_summary['all'][document_name] = zeroed_stats.copy()
    if instance_id is not None:
        if instance_id not in commands_summary:
            commands_summary[instance_id] = {}
            commands_summary[instance_id]['all'] = zeroed_stats.copy()
        if document_name not in commands_summary[instance_id]:
            commands_summary[instance_id][document_name] = zeroed_stats.copy()
    if status is not None:
        commands_summary['all']['all'][status] += 1
        commands_summary['all'][document_name][status] += 1
        if instance_id is not None:
            commands_summary[instance_id]['all'][status] += 1
            commands_summary[instance_id][document_name][status] += 1


def get_commands_summary(commands_json, command_invocations_json, tags_dict, associations_dict, verbose, start_timestamp, end_timestamp):
    """Aggregate all SSM command stats"""

    commands_summary = {}

    # add zeroed stats for all documents. To ensure cloudwatch metric widgets/alarms work properly
    for command in commands_json['Commands']:
        document_name = command['DocumentName']
        add_commands_stat(commands_summary, None, document_name, None)

    for command in command_invocations_json['CommandInvocations']:
        requested_datetime = command['RequestedDateTime']
        if "." in requested_datetime:
            timestamp = datetime.datetime.strptime(requested_datetime, '%Y-%m-%dT%H:%M:%S.%f%z')
        else:
            timestamp = datetime.datetime.strptime(requested_datetime, '%Y-%m-%dT%H:%M:%S%z')
        command_id = command['CommandId']
        document_name = command['DocumentName']
        instance_id = command['InstanceId']
        comment = command['Comment']
        status = command['Status']
        comment_ids = comment.split(':')

        if timestamp < start_timestamp or timestamp >= end_timestamp:
            continue

        instance_tags = None
        if instance_id in tags_dict:
            instance_tags = tags_dict[instance_id]

        if document_name in IGNORE_FAILURES_WITHOUT_ASSOCIATION and len(
                comment_ids) != 2:
            add_commands_stat(commands_summary, instance_id, document_name,
                              'ignore')
            if verbose >= 2:
                sys.stderr.write(
                    f'Verbose2: InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} {comment} - not scheduled'
                    + os.linesep)
            continue
        if document_name in IGNORE_FAILURES_WITHOUT_ASSOCIATION and comment_ids[
                0] not in associations_dict:
            add_commands_stat(commands_summary, instance_id, document_name,
                              'ignore')
            if verbose >= 2:
                sys.stderr.write(
                    f'Verbose2: InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} {comment} - association not found'
                    + os.linesep)
            continue
        if status == 'InProgress':
            add_commands_stat(commands_summary, instance_id, document_name,
                              'ignore')
            if verbose >= 2:
                sys.stderr.write(
                    f'Verbose2: InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - still running'
                    + os.linesep)
            continue
        if instance_tags is None:
            add_commands_stat(commands_summary, instance_id, document_name,
                              'ignore')
            if verbose >= 2:
                sys.stderr.write(
                    f'Verbose2: InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - EC2 not found'
                    + os.linesep)
            continue
        if is_status_ignorable(document_name, status, instance_tags):
            add_commands_stat(commands_summary, instance_id, document_name,
                              'ignore')
            if verbose >= 2:
                sys.stderr.write(
                    f'Verbose2: InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - in ignore list'
                    + os.linesep)
            continue
        if status == 'Success':
            add_commands_stat(commands_summary, instance_id, document_name,
                              'success')
        else:
            add_commands_stat(commands_summary, instance_id, document_name,
                              'failed')
            if verbose >= 1:
                sys.stderr.write(
                    f'Verbose1: InstanceId={instance_id} CommandId={command_id}: {document_name} {status}'
                    + os.linesep)
            if verbose >= 3:
                sys.stderr.write(
                    textwrap.indent(json.dumps(command, indent=1),
                                    'Verbose3: ') + os.linesep)
            if verbose >= 4:
                sys.stderr.write(
                    textwrap.indent(json.dumps(instance_tags, indent=1),
                                    'Verbose4: ') + os.linesep)
    return commands_summary


def print_commands_summary_csv(commands_summary, timestamp):
    """Print SSM command stats in CSV"""

    print('Timestamp,InstanceId,DocumentName,SuccessCount,FailedCount,IgnoreCount')
    for instance_id in commands_summary.keys():
        for command_key in commands_summary[instance_id].keys():
            command = commands_summary[instance_id][command_key]
            print(
                f'{timestamp},{instance_id},{command_key},{command["success"]},{command["failed"]},{command["ignore"]}'
            )


def main():
    """Main function"""
    global AWSCLI_COMMON_ARGS

    parser = argparse.ArgumentParser(
        description='Check SSM command invocations status')
    parser.add_argument('-i',
                        '--interval',
                        required=True,
                        type=int,
                        help='Check SSM commands for this time interval in seconds')
    parser.add_argument('-p',
                        '--profile',
                        type=str,
                        help='Optional profile to use for aws cli')
    parser.add_argument('-r',
                        '--round',
                        action='store_true',
                        help='Round the time interval checked, e.g. if 3600, check from 14:00 to 15:00')
    parser.add_argument(
        '-v',
        '--verbose',
        action='count',
        default=0,
        help=
        'Verbose output, -v=show failure summary, -vv=show ignore summary, -vvv=show failure detail, -vvvv=show failure ec2 instance tags'
    )

    args = parser.parse_args()

    timestamp = datetime.datetime.now(datetime.timezone.utc)
    timestamp = timestamp.replace(microsecond=0)
    if args.round:
        epoch_time = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
        delta = int((timestamp - epoch_time).total_seconds()) % args.interval
        end_timestamp = timestamp - datetime.timedelta(seconds=delta)
        start_timestamp = end_timestamp - datetime.timedelta(seconds=args.interval)
        invoke_after_timestamp = start_timestamp - datetime.timedelta(seconds=60)
    else:
        start_timestamp = timestamp - datetime.timedelta(seconds=args.interval)
        end_timestamp = timestamp
        invoke_after_timestamp = start_timestamp
    one_day_ago_timestamp = timestamp - datetime.timedelta(days=1)

    if args.profile:
        AWSCLI_COMMON_ARGS += ["--profile", args.profile]

    tags_json = describe_tags()
    tags_dict = tags_json_to_instance_dict(tags_json)
    associations_json = list_associations()
    associations_dict = associations_json_to_associations_dict(associations_json)
    commands_json = list_commands(one_day_ago_timestamp)
    command_invocations_json = list_command_invocations(invoke_after_timestamp)
    commands_summary = get_commands_summary(commands_json,
                                            command_invocations_json,
                                            tags_dict,
                                            associations_dict,
                                            args.verbose,
                                            start_timestamp,
                                            end_timestamp)
    print_commands_summary_csv(commands_summary, end_timestamp.strftime("%Y-%m-%dT%TZ"))


main()
