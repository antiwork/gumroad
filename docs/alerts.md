# Alerts

Check to see if certain EC2 instances are unhealthy by [listing all the individual EC2 instances matching the blue|green clusters](https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#Instances:search=blue%7Cgreen;sort=tag:Name) and clicking monitoring.

Recycle the unhealthy instances by [terminating them](https://console.aws.amazon.com/ec2/v2/home?region=us-east-1#Instances:sort=tag:Name) (50% first, then the other 50% after five minutes). Note: **Make sure not to terminate steward instances**. Please follow [these steps](https://github.com/antiwork/infrastructure/blob/master/docs/upgrading_stewards.md) to recycle steward instances.

You can look into container statistics with Hashi-UI. Please follow these steps to access it:

```
$ cd nomad
$ source nomad_proxy_functions.sh
$ proxy_on production
```

Then navigate to http://localhost:8080/nomad/production/allocations to see containers and their status. If the container has issues with sending requests to Vault (which can be seen in container status), check the CPU/Disk status of steward servers.

## Clues

Here are the things to look for immediately in the Bugsnags:

1. Cannot find Purchase/User/Link with id=#
2. NoMethodError: undefined method `[]' for nil:NilClass (and the line here has to do with Mongo)
3. If Bugsnag is not showing anything, but users are complaining, check out https://gumroad.com/admin/sidekiq and see the Processing list at the bottom. If any job is processing for over 1 minute, then that worker is in a bad state.
4. No space left on device
5. Don't trust Cloudwatch average metrics for a group, because almost all servers may be Healthy, not receiving any traffic, and the average will look totally normal. Check all instances individually to see what they're doing, re CPU/RAM utilization.
6. Following on point before, nomad might give some clues on (blue/green) web workers not processing traffic. EC2 Status ≠ Container status.

## What To Do

1. There is a replica lag. Go into the [AWS Console](https://<AWS_ACCOUNT_ID>.signin.aws.amazon.com/console) --> RDS --> Instances and show monitoring on the Production Replica. If the lag is very high, follow this [commit](https://github.com/gumroad/web/commit/14a50ecde5ee557be12fc14906d6b443cce9d352) to remove the replica and use master directly. Make sure to revert/undo this once the lag is gone and push the commits to master --> deploy --> staging.
2. This is usually a sign that [mLab](https://status.mlab.com/) is having some issue and you can check the status of it [here](https://status.compose.io/).
3. The worker is in a bad state so we want to stop and start it. In most cases, a reboot will work, but a start and stop will always work and is the safer route to take. Go into the [AWS Console](https://<AWS_ACCOUNT_ID>.signin.aws.amazon.com/console) --> EC2 --> Instances, find the worker in the list, go to actions and stop it. Once it is stopped, start it, and watch Sidekiq to see it is back working and not hung on jobs. It takes 2-3 minutes for a machine to start up again.
4. This is a lot more complicated. First, go to [New Relic](https://rpm.newrelic.com/accounts/85918/servers) and see which workers have a high disk usage. Go into the [AWS Console](https://<AWS_ACCOUNT_ID>.signin.aws.amazon.com/console) --> EC2 --> Instances and stop & start those workers. This is usually a good way to go. Once the machines have stopped and started, check New Relic again and see that the disk usage has gone down. If not, `ssh` into the worker and run `sudo rm -rf /tmp/*`. You may get errors saying "Operation not permitted", nothing to do about that. Then follow these steps:

```
grd
cd ..
ls -l
```

Take note of the directory `current` links to. Then:

```
cd releases
ls -l
```

You want to remove all the past deploys using `rm -rf [name]` where the name is NOT the one `current` links to. If the size of the directory `current` links to is huge, then you have no choice but to make some change to the code, deploy to production, and remove that directory which is now old as `current` will link to the new deploy.

5. If containers are not receiving any traffic, try restart on EC2 for the green/blue servers. Containers might not have allocated properly on deploy.

## Server Disks Full

You will get an alert saying the `Fullest disk > 90%`. First check [New Relic](https://rpm.newrelic.com/accounts/85918/servers) to see which servers they are. 'ssh' into the server and run:

```
sudo rm -rf /tmp/*
```

After that, run:

```
sudo find / -type f -size +20M -exec ls -lh {} \\;
```

This will tell you all files larger than 20MB. Likely it will be a log directory that is exploding. If not, make sure to examine what you are removing before you actually remove it. If it is safe to remove, remove the files and/or directories. Check [New Relic](https://rpm.newrelic.com/accounts/85918/servers) to ensure the disk usage went down. If not, try starting the stopping the instance. HOWEVER, follow the directions [here](https://github.com/antiwork/gumroad/wiki/Upgrading-AWS-instances#how-to-run-the-rolling-upgrade-on-production) to ensure the site does not go down.

## Checking connectivity

In our production environment (and generally anywhere) you can use the following commands to check connectivity, SSL, etc.

### Checking connectivity to a port, or that a port is open

```
nc -z -w 5 [host] [port]
```

where:

- `-z` tells it to try connecting then tell us :+1: or :-1:
- `-w 5` only wait 5 seconds

### Checking or getting SSL certs for a hostname

```
openssl s_client -showcerts -connect [host]:[port]
```
