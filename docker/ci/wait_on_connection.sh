#!/bin/bash

set -e

until nc -z $1 $2;
do
    sleep 1
done
