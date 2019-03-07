#!/usr/bin/env bash

PYENV_ROOT="${PYENV_ROOT:-$HOME/.travis-pyenv}"
PYENV_CACHE_PATH="${PYENV_CACHE_PATH:-$HOME/.pyenv_cache}"

export PYENV_ROOT
export PYENV_CACHE_PATH

_verbose=0
_debug=0

if [[ -n $CI ]]; then
	_verbose=1
	_debug=1
fi

__travis() {
	local action=$1 name=$2
	if [[ $TRAVIS == true ]]; then
		echo -en "travis_fold:${action}:${name}\\r\\033[0K"
	fi
}

__msg() {
	local -r level=$1
	shift

	printf -v fmt -- '%s %-8s **** %%s\n' "$(date +%c)" "$level"
	# this is intentional so that the fmt string captures the timestamp and log level
	# shellcheck disable=SC2059
	printf -- "$fmt" "$@"
}

__die() {
	__msg "FATAL" "$@" >&2
	exit 1
}

__warn() {
	__msg "WARNING" "$@"
}

__info() {
	if ((_verbose || _debug)); then
		__msg "INFO" "$@"
	fi
}

__debug() {
	if ((_debug)); then
		__msg "DEBUG" "$@"
	fi
}

usage() {
	cat <<- EOF
		Usage: $(basename "$0") [OPTIONS] [--] version [version version...]
		
		Arguments:
		    version         provide one or more python versions to install; if not provided, looks for
		                    the \$PYENV_VERSION environment variable
		
		Options
		    --              Stop parsing command line arguments.
		    -r DIRECTORY    Set the PYENV_ROOT (default '$PYENV_ROOT')
		    -c DIRECTORY    Set the cache directory (default '$PYENV_CACHE_PATH')
		    -v              Verbose output.
		    -d              Debugging output.
		    -h              Display this message and exit.
	EOF

	if (($1)); then
		__die "Missing argument."
	else
		exit 0
	fi
}

__exec() {
	__debug "exec: $*"
	"$@"
}

version_pyenv_path() {
	local -r python_version="$1"
	if [[ -z $python_version ]]; then
		die 'python_version not provided!'
	fi

	echo -n "$PYENV_ROOT/versions/$python_version"
}

version_cache_path() {
	local -r python_version="$1"
	if [[ -z $python_version ]]; then
		die 'python_version not provided!'
	fi

	echo -n "$PYENV_CACHE_PATH/$python_version"
}

verify_python() {
	local -r python_bin="$1"
	if [[ -z $python_bin ]]; then
		die 'python_bin not provided!'
	fi

	__exec "$python_bin" --version
}

use_existing_python() {
	local -r python_version="$1"
	if [[ -z $python_version ]]; then
		__die 'python_version not provided!'
	fi

	local -r path=$(version_pyenv_path "$python_version")
	__debug "Checking for a valid python install at $path"

	if [[ -d $path ]]; then
		__info "Python $python_version already installed. Verifying..."
		if verify_python "$path/bin/python"; then
			__info "Success!"
			return 0
		else
			__info "FAILED." "Clearing installed version..."
			rm -f "$path"
			__info "done."
			return 1
		fi
	else
		__info "No existing python found."
		return 1
	fi
}

use_cached_python() {
	local -r python_version="$1"
	if [[ -z $python_version ]]; then
		__die 'python_version not provided!'
	fi

	local -r pyenv_path=$(version_pyenv_path "$python_version")
	local -r cache_path=$(version_cache_path "$python_version")
	__debug "Checking for a valid python install at $cache_path"

	if [[ -d $cache_path ]]; then
		__info "Cached python found, $python_version. Verifying..."
		ln -sfv "$cache_path" "$pyenv_path"
		if verify_python "$pyenv_path/bin/python"; then
			__info "success!"
			return 0
		else
			__info "FAILED." "Clearing cached version..."
			rm -f "$pyenv_path"
			rm -rf "$cache_path"
			__info "done."
			return 1
		fi
	else
		__info 'No cached python found.'
		return 1
	fi
}

install_pyenv() {
	if [[ -d "$PYENV_ROOT/.git" ]]; then
		__debug "Updating existing pyenv installation"
		__exec git --work-tree="$PYENV_ROOT" --git-dir="$PYENV_ROOT/.git" pull origin master
		__debug "done"
	else
		__debug "Installing pyenv to $PYENV_ROOT"
		__exec git clone --depth 1 "https://github.com/pyenv/pyenv.git" "$PYENV_ROOT"
		__debug "done"
	fi

	export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
	hash -d pyenv 2> /dev/null || true
	__exec pyenv --version
	__exec pyenv versions
}

install_python() {
	local -r python_version="$1"
	if [[ -z $python_version ]]; then
		__die 'python_version not provided!'
	fi

	local -r pyenv_path=$(version_pyenv_path "$python_version")
	local -r cache_path=$(version_cache_path "$python_version")

	__info "Trying to find and use cached python $python_version."
	if ! use_existing_python "$python_version" && ! use_cached_python "$python_version"; then
		__warn "Installing Python $python_version with pyenv now."
		if __exec pyenv install "$python_version"; then
			if __exec mv "$pyenv_path" "$PYENV_CACHE_PATH"; then
				__info 'Python was successfully built and moved to cache.'
				__info "Trying to find and use cached python $python_version."
				if ! use_cached_python "$python_version"; then
					__warn "Python version $python_version was apparently successfully built with pyenv, but, once cached, it could not be verified."
					return 1
				fi
			else
				__warn 'Python was succesfully built, but moving to cache failed. Preceding anyway without caching.'
			fi
		else
			__warn "Python version $python_version build FAILED."
			return 1
		fi
	fi
}

# prevent block from executing until completely parsed
{
	if [[ -n $VIRTUAL_ENV ]]; then
		deactivate
	fi

	while getopts "r:c:vdh" opt; do
		case "$opt" in
		r)
			PYENV_ROOT=$OPTARG
			export PYENV_ROOT
			;;
		c)
			PYENV_CACHE_ROOT=$OPTARG
			export PYENV_CACHE_ROOT
			;;
		v)
			_verbose=1
			;;
		d)
			_debug=1
			;;
		h)
			usage 0
			;;
		*)
			usage 0
			__die "Invalid flag $opt"
			;;
		esac
	done

	shift $((OPTIND - 1))

	if [[ $# -eq 0 && -n $PYTHON_VERSIONS ]]; then
		# intentionally unquoted
		# shellcheck disable=SC2086
		set -- $PYTHON_VERSIONS
	fi

	if [[ $# -eq 0 && -z $PYENV_VERSION ]]; then
		usage 1
	fi

	__travis start setup-pyenv
	install_pyenv
	# doesn't exist sometimes
	mkdir -p "$PYENV_ROOT/versions"
	echo -n > "$PYENV_ROOT/version"
	__travis end setup-pyenv

	fail=0
	while (($#)); do
		__travis start "$1"
		__info "Installing Python $1"
		if install_python "$1"; then
			__info "Success!"
			echo "$1" >> "$PYENV_ROOT/version"
		else
			__warn "Failed to install Python $1"
			fail+=1
		fi
		__travis end "$1"
		shift
	done

	return $fail
}
