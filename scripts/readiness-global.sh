#!/bin/bash
targetcli /iscsi ls | grep -q 'iqn' && \
[ $(targetcli /iscsi ls | grep -c 'o- lun') -gt 0 ] && \
ss -tlnp | grep -q ':3260'
