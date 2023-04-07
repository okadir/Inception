#!/bin/sh

# Copyright (c) 2002, 2016, Oracle and/or its affiliates. All rights reserved.
# 
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335  USA

config=".my.cnf.$$"
command=".mysql.$$"

trap "interrupt" 1 2 3 6 15

rootpass=""
echo_n=
echo_c=
basedir=
defaults_file=
defaults_extra_file=
no_defaults=

parse_arg()
{
  echo "$1" | sed -e 's/^[^=]*=//'
}

parse_arguments()
{
  # We only need to pass arguments through to the server if we don't
  # handle them here.  So, we collect unrecognized options (passed on
  # the command line) into the args variable.
  pick_args=
  if test "$1" = PICK-ARGS-FROM-ARGV
  then
    pick_args=1
    shift
  fi

  for arg
  do
    case "$arg" in
      --basedir=*) basedir=`parse_arg "$arg"` ;;
      --defaults-file=*) defaults_file="$arg" ;;
      --defaults-extra-file=*) defaults_extra_file="$arg" ;;
      --no-defaults) no_defaults="$arg" ;;
      *)
        if test -n "$pick_args"
        then
          # This sed command makes sure that any special chars are quoted,
          # so the arg gets passed exactly to the server.
          # XXX: This is broken; true fix requires using eval and proper
          # quoting of every single arg ($basedir, $ldata, etc.)
          #args="$args "`echo "$arg" | sed -e 's,\([^a-zA-Z0-9_.-]\),\\\\\1,g'`
          args="$args $arg"
        fi
        ;;
    esac
  done
}

# Try to find a specific file within --basedir which can either be a binary
# release or installed source directory and return the path.
find_in_basedir()
{
  return_dir=0
  found=0
  case "$1" in
    --dir)
      return_dir=1; shift
      ;;
  esac

  file=$1; shift

  for dir in "$@"
  do
    if test -f "$basedir/$dir/$file"
    then
      found=1
      if test $return_dir -eq 1
      then
        echo "$basedir/$dir"
      else
        echo "$basedir/$dir/$file"
      fi
      break
    fi
  done

  if test $found -eq 0
  then
      # Test if command is in PATH
      $file --no-defaults --version > /dev/null 2>&1
      status=$?
      if test $status -eq 0
      then
        echo $file
      fi
  fi
}

cannot_find_file()
{
  echo
  echo "FATAL ERROR: Could not find $1"

  shift
  if test $# -ne 0
  then
    echo
    echo "The following directories were searched:"
    echo
    for dir in "$@"
    do
      echo "    $dir"
    done
  fi

  echo
  echo "If you compiled from source, you need to run 'make install' to"
  echo "copy the software into the correct location ready for operation."
  echo
  echo "If you are using a binary release, you must either be at the top"
  echo "level of the extracted archive, or pass the --basedir option"
  echo "pointing to that location."
  echo
}

# Ok, let's go.  We first need to parse arguments which are required by
# my_print_defaults so that we can execute it first, then later re-parse
# the command line to add any extra bits that we need.
parse_arguments PICK-ARGS-FROM-ARGV "$@"

#
# We can now find my_print_defaults.  This script supports:
#
#   --srcdir=path pointing to compiled source tree
#   --basedir=path pointing to installed binary location
#
# or default to compiled-in locations.
#

if test -n "$basedir"
then
  print_defaults=`find_in_basedir my_print_defaults bin extra`
  echo "print: $print_defaults"
  if test -z "$print_defaults"
  then
    cannot_find_file my_print_defaults $basedir/bin $basedir/extra
    exit 1
  fi
  mysql_command=`find_in_basedir mysql bin`
  if test -z "$mysql_command"
  then
    cannot_find_file mysql $basedir/bin
    exit 1
  fi
else
  print_defaults="/usr/bin/my_print_defaults"
  mysql_command="/usr/bin/mysql"
fi

if test ! -x "$print_defaults"
then
  cannot_find_file "$print_defaults"
  exit 1
fi

if test ! -x "$mysql_command"
then
  cannot_find_file "$mysql_command"
  exit 1
fi

# Now we can get arguments from the group [client] and [client-server]
# in the my.cfg file, then re-run to merge with command line arguments.
parse_arguments `$print_defaults $defaults_file $defaults_extra_file $no_defaults client client-server client-mariadb`
parse_arguments PICK-ARGS-FROM-ARGV "$@"

set_echo_compat() {
    case `echo "testing\c"`,`echo -n testing` in
        *c*,-n*) echo_n=   echo_c=     ;;
        *c*,*)   echo_n=-n echo_c=     ;;
        *)       echo_n=   echo_c='\c' ;;
    esac
}

validate_reply () {
    ret=0
    if [ -z "$1" ]; then
        reply=y
        return $ret
    fi
    case $1 in
        y|Y|yes|Yes|YES) reply=y ;;
        n|N|no|No|NO)    reply=n ;;
        *) ret=1 ;;
    esac
    return $ret
}

prepare() {
    touch $config $command
    chmod 600 $config $command
}

do_query() {
    echo "$1" >$command
    #sed 's,^,> ,' < $command  # Debugging
    $mysql_command --defaults-file=$config $defaults_extra_file $no_defaults $args <$command
    return $?
}

# Simple escape mechanism (\-escape any ' and \), suitable for two contexts:
# - single-quoted SQL strings
# - single-quoted option values on the right hand side of = in my.cnf
#
# These two contexts don't handle escapes identically.  SQL strings allow
# quoting any character (\C => C, for any C), but my.cnf parsing allows
# quoting only \, ' or ".  For example, password='a\b' quotes a 3-character
# string in my.cnf, but a 2-character string in SQL.
#
# This simple escape works correctly in both places.
basic_single_escape () {
    # The quoting on this sed command is a bit complex.  Single-quoted strings
    # don't allow *any* escape mechanism, so they cannot contain a single
    # quote.  The string sed gets (as argv[1]) is:  s/\(['\]\)/\\\1/g
    #
    # Inside a character class, \ and ' are not special, so the ['\] character
    # class is balanced and contains two characters.
    echo "$1" | sed 's/\(['"'"'\]\)/\\\1/g'
}

#
# create a simple my.cnf file to be able to pass the root password to the mysql
# client without putting it on the command line
#
make_config() {
    echo "# mysql_secure_installation config file" >$config
    echo "[mysql]" >>$config
    echo "user=root" >>$config
    esc_pass=`basic_single_escape "$rootpass"`
    echo "password='$esc_pass'" >>$config
    #sed 's,^,> ,' < $config  # Debugging

    if test -n "$defaults_file"
    then
        dfile=`parse_arg "$defaults_file"`
        cat "$dfile" >>$config
    fi
}

get_root_password() {
    status=1
    while [ $status -eq 1 ]; do
        stty -echo
        echo $echo_n "Enter current password for root (enter for none): $echo_c"
        password=""
        echo
        stty echo
        if [ "x$password" = "x" ]; then
            hadpass=0
        else
            hadpass=1
        fi
        rootpass=$password
        make_config
        do_query ""
        status=$?
    done
    echo "OK, successfully used password, moving on..."
    echo
}

set_root_password() {
    stty -echo
    echo $echo_n "New password: $echo_c"
    password1=$MARIADB_ROOT_PASSWORD
    echo

    esc_pass=`basic_single_escape "$password1"`
    do_query "UPDATE mysql.user SET Password=PASSWORD('$esc_pass') WHERE User='root';"
    if [ $? -eq 0 ]; then
        echo "Password updated successfully!"
        echo "Reloading privilege tables.."
        reload_privilege_tables
        if [ $? -eq 1 ]; then
                clean_and_exit
        fi
        echo
        rootpass=$password1
        make_config
    else
        echo "Password update failed!"
        clean_and_exit
    fi

    return 0
}

remove_anonymous_users() {
    do_query "DELETE FROM mysql.user WHERE User='';"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!"
        clean_and_exit
    fi

    return 0
}

#
# CREATE  db user
#

create_db_user() {
    do_query "GRANT ALL ON *.* TO '$DB_USER'@'localhost' IDENTIFIED BY '$USER_PASS' WITH GRANT OPTION;"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!"
        clean_and_exit
    fi

    return 0
}

#
# CREATE database

create_db() {
    do_query "CREATE [OR REPLACE] {DATABASE | SCHEMA} [IF NOT EXISTS] $DB_NAME"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!"
        clean_and_exit
    fi

    return 0
}

remove_remote_root() {
    do_query "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!"
    fi
}

remove_test_database() {
    echo " - Dropping test database..."
    do_query "DROP DATABASE IF EXISTS test;"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!  Not critical, keep moving..."
    fi

    echo " - Removing privileges on test database..."
    do_query "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
    else
        echo " ... Failed!  Not critical, keep moving..."
    fi

    return 0
}

reload_privilege_tables() {
    do_query "FLUSH PRIVILEGES;"
    if [ $? -eq 0 ]; then
        echo " ... Success!"
        return 0
    else
        echo " ... Failed!"
        return 1
    fi
}

interrupt() {
    echo
    echo "Aborting!"
    echo
    cleanup
    stty echo
    exit 1
}

cleanup() {
    echo "Cleaning up..."
    rm -f $config $command
}

# Remove the files before exiting.
clean_and_exit() {
        cleanup
        exit 1
}

# The actual script starts here

prepare
set_echo_compat

echo
echo "NOTE: RUNNING ALL PARTS OF THIS SCRIPT IS RECOMMENDED FOR ALL MariaDB"
echo "      SERVERS IN PRODUCTION USE!  PLEASE READ EACH STEP CAREFULLY!"
echo
echo "In order to log into MariaDB to secure it, we'll need the current"
echo "password for the root user.  If you've just installed MariaDB, and"
echo "you haven't set the root password yet, the password will be blank,"
echo "so you should just press enter here."
echo

get_root_password


#
# Set the root password
#

echo "Setting the root password ensures that nobody can log into the MariaDB"

set_root_password

echo


#
# Remove anonymous users
#



remove_anonymous_users

echo


#
# CREATE DB_USER
#

create_db_user

echo


#
# CREATE database
#

create_db


#
# Disallow remote root login
#

echo "Normally, root should only be allowed to connect from 'localhost'.  This"
echo "ensures that someone cannot guess at the root password from the network."

remove_remote_root

echo


#
# Remove test database
#

echo "By default, MariaDB comes with a database named 'test' that anyone can"
echo "access.  This is also intended only for testing, and should be removed"
echo "before moving into a production environment."
echo

remove_test_database

echo


#
# Reload privilege tables
#

echo "Reloading the privilege tables will ensure that all changes made so far"
echo "will take effect immediately."

reload_privilege_tables
echo

cleanup

echo
echo "All done!  If you've completed all of the above steps, your MariaDB"
echo "installation should now be secure."
echo
echo "Thanks for using MariaDB!"