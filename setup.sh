#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="$SCRIPT_DIR/config.conf"
CONFIG_DEST_DIR="$HOME/.config/mango"
CONFIG_DEST_FILE="$CONFIG_DEST_DIR/config.conf"

MANGOWC_REPO="${MANGOWC_REPO:-}"
NOCTALIA_REPO="${NOCTALIA_REPO:-}"
PKG_CACHE_READY=0
TOTAL_STEPS=4
CURRENT_STEP=0

if command -v sudo >/dev/null 2>&1; then
	SUDO="sudo"
else
	SUDO=""
fi

log_info() {
	printf '[INFO] %s\n' "$*"
}

log_warn() {
	printf '[WARN] %s\n' "$*"
}

log_error() {
	printf '[ERROR] %s\n' "$*" >&2
}

step() {
	CURRENT_STEP=$((CURRENT_STEP + 1))
	printf '\n[%d/%d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$*"
}

die() {
	log_error "$*"
	exit 1
}

on_error() {
	local exit_code="$1"
	local line_no="$2"
	local command="$3"
	log_error "Command failed at line $line_no: $command"
	exit "$exit_code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

require_file() {
	local file_path="$1"
	[[ -f "$file_path" ]] || die "Required file not found: $file_path"
}

ensure_pkg_metadata() {
	local manager="$1"
	if [[ "$PKG_CACHE_READY" -eq 1 ]]; then
		return
	fi

	case "$manager" in
		apt)
			log_info "Refreshing apt package metadata"
			$SUDO apt-get update
			;;
		dnf)
			log_info "Refreshing dnf package metadata"
			$SUDO dnf makecache
			;;
		pacman)
			log_info "Refreshing pacman package metadata"
			$SUDO pacman -Sy --noconfirm
			;;
		zypper)
			log_info "Refreshing zypper package metadata"
			$SUDO zypper --non-interactive refresh
			;;
		*)
			die "Unsupported package manager: $manager"
			;;
	esac

	PKG_CACHE_READY=1
}

package_exists() {
	local manager="$1"
	local package="$2"

	case "$manager" in
		apt)
			apt-cache show "$package" >/dev/null 2>&1
			;;
		dnf)
			dnf info "$package" >/dev/null 2>&1
			;;
		pacman)
			pacman -Si "$package" >/dev/null 2>&1
			;;
		zypper)
			zypper --non-interactive info "$package" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

run_pkg_install() {
	local manager="$1"
	shift
	ensure_pkg_metadata "$manager"
	log_info "Installing packages: $*"
	case "$manager" in
		apt)
			$SUDO apt-get install -y "$@"
			;;
		dnf)
			$SUDO dnf install -y "$@"
			;;
		pacman)
			$SUDO pacman -S --needed --noconfirm "$@"
			;;
		zypper)
			$SUDO zypper --non-interactive install "$@"
			;;
		*)
			die "Unsupported package manager: $manager"
			;;
	esac
}

install_dependencies() {
	local manager="$1"
	step "Installing MangoWC dependencies with $manager"
	case "$manager" in
		apt)
			run_pkg_install "$manager" \
				build-essential git meson ninja-build pkg-config cmake curl \
				wayland-protocols libwayland-dev libxkbcommon-dev libpixman-1-dev \
				libdrm-dev libinput-dev libxcb1-dev libxcb-composite0-dev \
				libxcb-xfixes0-dev libxcb-res0-dev libxcb-icccm4-dev \
				libxcb-ewmh-dev libxcb-errors-dev libseat-dev libcairo2-dev \
				libpango1.0-dev libpam0g-dev xwayland mate-polkit
			;;
		dnf)
			run_pkg_install "$manager" \
				@development-tools git meson ninja-build pkgconf-pkg-config cmake curl \
				wayland-devel wayland-protocols-devel libxkbcommon-devel pixman-devel \
				libdrm-devel libinput-devel libxcb-devel xcb-util-devel \
				xcb-util-wm-devel xcb-util-errors-devel seatd-devel cairo-devel \
				pango-devel pam-devel xorg-x11-server-Xwayland mate-polkit
			;;
		pacman)
			run_pkg_install "$manager" \
				base-devel git meson ninja pkgconf cmake curl wayland \
				wayland-protocols wlroots xorg-xwayland libxkbcommon pixman libdrm \
				libinput libxcb xcb-util xcb-util-wm xcb-util-errors libseat cairo \
				pango pam mate-polkit
			;;
		zypper)
			run_pkg_install "$manager" \
				-t pattern devel_basis
			run_pkg_install "$manager" \
				git meson ninja pkg-config cmake curl wayland-devel \
				wayland-protocols-devel wlroots-devel libxkbcommon-devel \
				pixman-devel libdrm-devel libinput-devel libxcb-devel \
				xcb-util-devel xcb-util-wm-devel seatd-devel cairo-devel \
				pango-devel pam-devel xwayland mate-polkit
			;;
		*)
			die "Unsupported package manager: $manager"
			;;
	esac
}

detect_pkg_manager() {
	if command -v apt-get >/dev/null 2>&1; then
		echo "apt"
	elif command -v dnf >/dev/null 2>&1; then
		echo "dnf"
	elif command -v pacman >/dev/null 2>&1; then
		echo "pacman"
	elif command -v zypper >/dev/null 2>&1; then
		echo "zypper"
	else
		echo ""
	fi
}

try_install_mangowc_package() {
	local manager="$1"
	ensure_pkg_metadata "$manager"
	if ! package_exists "$manager" mangowc; then
		log_warn "mangowc package not found in $manager repositories"
		return 1
	fi

	log_info "Found mangowc in package manager, installing"
	if run_pkg_install "$manager" mangowc; then
		return 0
	fi

	log_warn "mangowc package installation failed"
	return 1
}

build_mangowc_from_source() {
	local repo_url="$1"
	local tmp_dir
	tmp_dir="$(mktemp -d)"
	log_info "Building MangoWC from source: $repo_url"
	git clone --depth=1 "$repo_url" "$tmp_dir/mangowc"
	cd "$tmp_dir/mangowc"
	meson setup build
	ninja -C build
	$SUDO ninja -C build install
	cd "$SCRIPT_DIR"
	rm -rf "$tmp_dir"
}

install_mangowc() {
	local manager="$1"
	step "Installing MangoWC"
	if command -v mangowc >/dev/null 2>&1; then
		log_info "MangoWC is already installed"
		return
	fi

	if try_install_mangowc_package "$manager"; then
		log_info "MangoWC installed from package manager"
		return
	fi

	if [[ -z "$MANGOWC_REPO" ]]; then
		die "Could not install mangowc from package manager. Set MANGOWC_REPO to a valid git URL to build from source."
	fi

	build_mangowc_from_source "$MANGOWC_REPO"
}

install_config() {
	step "Installing config.conf"
	log_info "Installing config.conf to $CONFIG_DEST_FILE"
	mkdir -p "$CONFIG_DEST_DIR"
	install -m 644 "$CONFIG_SOURCE" "$CONFIG_DEST_FILE"
}

setup_noctalia() {
	local manager="$1"
	step "Setting up Noctalia"
	ensure_pkg_metadata "$manager"

	if package_exists "$manager" noctalia; then
		log_info "Found noctalia package, installing"
		if run_pkg_install "$manager" noctalia; then
			log_info "Noctalia installed from package manager"
			return
		fi
		log_warn "Noctalia package install failed"
	else
		log_warn "noctalia package not found in $manager repositories"
	fi

	if package_exists "$manager" noctalia-theme; then
		log_info "Found noctalia-theme package, installing"
		if run_pkg_install "$manager" noctalia-theme; then
			log_info "Noctalia theme installed from package manager"
			return
		fi
		log_warn "Noctalia-theme package install failed"
	else
		log_warn "noctalia-theme package not found in $manager repositories"
	fi

	if [[ -n "$NOCTALIA_REPO" ]]; then
		local tmp_dir
		tmp_dir="$(mktemp -d)"
		log_info "Setting up Noctalia from source: $NOCTALIA_REPO"
		git clone --depth=1 "$NOCTALIA_REPO" "$tmp_dir/noctalia"

		if [[ -x "$tmp_dir/noctalia/install.sh" ]]; then
			(cd "$tmp_dir/noctalia" && bash ./install.sh)
		elif [[ -f "$tmp_dir/noctalia/install.sh" ]]; then
			(cd "$tmp_dir/noctalia" && chmod +x ./install.sh && bash ./install.sh)
		else
			mkdir -p "$HOME/.themes" "$HOME/.icons"
			if [[ -d "$tmp_dir/noctalia/themes" ]]; then
				cp -r "$tmp_dir/noctalia/themes/." "$HOME/.themes/"
			fi
			if [[ -d "$tmp_dir/noctalia/icons" ]]; then
				cp -r "$tmp_dir/noctalia/icons/." "$HOME/.icons/"
			fi
		fi

		rm -rf "$tmp_dir"
		log_info "Noctalia setup complete"
		return
	fi

	log_warn "Noctalia package was not found. Set NOCTALIA_REPO to a valid git URL to install from source."
}

main() {
	local manager
	require_file "$CONFIG_SOURCE"
	manager="$(detect_pkg_manager)"

	if [[ -z "$manager" ]]; then
		die "No supported package manager found (apt, dnf, pacman, zypper)."
	fi

	log_info "Detected package manager: $manager"

	install_dependencies "$manager"
	install_mangowc "$manager"
	install_config
	setup_noctalia "$manager"

	printf '\n'
	log_info "All tasks completed successfully"
}

main "$@"
