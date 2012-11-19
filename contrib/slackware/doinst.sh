#!/bin/sh









config() {
	NEW="$1"
	OLD="`dirname $NEW`/`basename $NEW .new`"

	# If there's no config file by that name, mv it over:
	if [ ! -r "$OLD" ]; then
		mv "$NEW" "$OLD"
	elif [ "`cat $OLD | md5sum`" = "`cat $NEW | md5sum`" ]; then # toss the redundant copy
		rm -f "$NEW"
	fi

	# Otherwise, we leave the .new copy for the admin to consider...
}

config etc/sysconfig/statcollector-agent.new

# restart service
/etc/rc.d/init.d/statcollector-agent restart >/dev/null 2>&1

# EOF
