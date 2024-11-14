import argparse
import json
import subprocess
import datetime 
import os
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
  # This seems to fail when windows server comes back up
  "AmazonInspector2-InvokeInspectorSsmPlugin" : [
    { "os-type": "Linux" }, 
    { "environment-name": "nomis-development","server-type": "NomisClient" }, 
    { "environment-name": "nomis-preproduction", "server-type": "NomisClient" },
    { "server-type": "NartClient" }, # doesn't support windows 2012
  ],
  "AmazonInspector2-InvokeInspectorSsmPluginLinux" : [
    { "os-type": "Windows" }, 
    { "server-type": "nomis-web" }, # doesn't support RHEL6 
    { "server-type": "onr-boe" }, # doesn't support RHEL6
    { "server-type": "onr-web" }, # doesn't support RHEL6
  ],
  "AmazonInspector2-ConfigureInspectorSsmPlugin": [
    { "os-type": "Linux" },
    { "server-type": "NartClient" }, # doesn't support windows 2012
  ],
  "AmazonInspector2-ConfigureInspectorSsmPluginLinux" : [
    { "os-type": "Windows" }, 
    { "server-type": "nomis-web" }, # doesn't support RHEL6
    { "server-type": "onr-boe" }, # doesn't support RHEL6
    { "server-type": "onr-web" }, # doesn't support RHEL6
  ],
  "AWSEC2-CreateVssSnapshot" : [
   { "application": "corporate-staff-rostering" }, # TODO: fix the backup policy
   { "application": "nomis-data-hub" },
   { "application": "oasys-national-reporting" },
   { "application": "planetfm" },
  ],
}

def run_aws_cli(cmd):
  cmd += AWSCLI_COMMON_ARGS
  result = subprocess.run(cmd,
                          capture_output=True,
                          text=True,
                          timeout=AWSCLI_TIMEOUT_SECS)
  if result.returncode != 0:
    raise ValueError(f'exit code {result.returncode} for cmd' + ' '.join(cmd) + os.linesep + result.stderr)
  return json.loads(result.stdout)

def describe_tags():
  cmd = [
    'aws',
    'ec2',
    'describe-tags',
    '--filters',
    'Name=resource-type,Values=instance'
  ]
  return run_aws_cli(cmd)

def list_associations():
  cmd = [
    'aws',
    'ssm',
    'list-associations',
  ]
  return run_aws_cli(cmd)

def list_command_invocations(timestamp):
  cmd = [
    'aws',
    'ssm',
    'list-command-invocations',
    '--filters',
    'key=InvokedAfter,value=' + timestamp.strftime("%Y-%m-%dT%TZ"),
  ]
  return run_aws_cli(cmd)

def tags_json_to_instance_dict(tags_json):
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
  associations_dict = {}
  for association in associations_json['Associations']:
    association_id = association['AssociationId']
    associations_dict[association_id] = association
  return associations_dict

def is_taglist_match(instance_tags, match_tags):
  for match_tag in match_tags.keys():
    if match_tag not in instance_tags.keys():
      return False
    if instance_tags[match_tag] != match_tags[match_tag]:
      return False
  return True

def is_status_ignorable(document_name, status, instance_tags):
  if document_name not in IGNORE_FAILURES_BY_TAGS:
    return False
  if status != 'Failed':
    return False
  for tag_list in IGNORE_FAILURES_BY_TAGS[document_name]:
    if is_taglist_match(instance_tags, tag_list):
      return True
  return False 

def get_commands_summary(commands_json, tags_dict, associations_dict, verbose):
  commands_summary = {}
  for command in commands_json['CommandInvocations']:
    command_id = command['CommandId']
    document_name = command['DocumentName']
    instance_id = command['InstanceId']
    comment = command['Comment']
    status = command['Status']
    instance_tags = None
    if instance_id in tags_dict:
      instance_tags = tags_dict[instance_id]
    comment_ids = comment.split(':')
    if document_name not in commands_summary:
      commands_summary[document_name] = {
        "ignore": 0,
        "success": 0,
        "failed": 0,
      }

    if document_name in IGNORE_FAILURES_WITHOUT_ASSOCIATION and len(comment_ids) != 2:
      commands_summary[document_name]['ignore'] += 1
      if verbose >= 3:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} {comment} - not scheduled'+os.linesep)
      continue
    if document_name in IGNORE_FAILURES_WITHOUT_ASSOCIATION and comment_ids[0] not in associations_dict:
      commands_summary[document_name]['ignore'] += 1
      if verbose >= 3:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} {comment} - association not found'+os.linesep)
      continue
    if status == 'InProgress':
      commands_summary[document_name]['ignore'] += 1
      if verbose >= 3:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - still running'+os.linesep)
      continue
    if instance_tags == None:
      commands_summary[document_name]['ignore'] += 1
      if verbose >= 3:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - EC2 not found'+os.linesep)
      continue
    if is_status_ignorable(document_name, status, instance_tags):
      commands_summary[document_name]['ignore'] += 1
      if verbose >= 3:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: ignoring {document_name} {status} - in ignore list'+os.linesep)
      continue
    if status == 'Success':
      commands_summary[document_name]['success'] += 1
    else:
      commands_summary[document_name]['failed'] += 1
      if verbose >= 1:
        sys.stderr.write(f'InstanceId={instance_id} CommandId={command_id}: {document_name} {status}'+os.linesep)
      if verbose >= 2:
        sys.stderr.write(json.dumps(command, indent=1)+os.linesep)
      if verbose >= 4:
        sys.stderr.write(json.dumps(instance_tags, indent=1)+os.linesep)
  return commands_summary

def print_commands_summary_csv(commands_summary):
  print('DocumentName,SuccessCount,FailedCount,IgnoreCount')
  for command_key in commands_summary.keys():
    command = commands_summary[command_key]
    print(f'{command_key},{command["success"]},{command["failed"]},{command["ignore"]}')
    
def main():
  global AWSCLI_COMMON_ARGS

  parser = argparse.ArgumentParser(description='Check SSM command invocations status')
  parser.add_argument('-s',
                      '--seconds',
                      required=True,
                      type=int,
                      help='Only check SSM commands run this time ago')
  parser.add_argument('-p',
                      '--profile',
                      type=str,
                      help='Optional profile to use for aws cli')
  parser.add_argument('-v',
                      '--verbose',
                      action='count',
                      default=0,
                      help='Verbose output, or -vv for extra verbose')

  args = parser.parse_args()

  timestamp = datetime.datetime.now()
  timestamp = timestamp - datetime.timedelta(seconds=args.seconds)
  if args.profile:
    AWSCLI_COMMON_ARGS += ["--profile", args.profile]

  tags_json = describe_tags()
  tags_dict = tags_json_to_instance_dict(tags_json)
  associations_json = list_associations()
  associations_dict = associations_json_to_associations_dict(associations_json)
  commands_json = list_command_invocations(timestamp)
  commands_summary = get_commands_summary(commands_json, tags_dict, associations_dict, args.verbose)
  print_commands_summary_csv(commands_summary)

main()
