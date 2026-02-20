#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SOURCE="$SCRIPT_DIR/config.conf"
CONFIG_DEST_DIR="$HOME/.config/mango"
CONFIG_DEST_FILE="$CONFIG_DEST_DIR/config.conf"

MANGOWC_REPO="${MANGOWC_REPO:-}"
NOCTALIA_REPO="${NOCTALIA_REPO:-}"
PKG_CACHE_READY=0
TOTAL_STEPS=5
CURRENT_STEP=0

command_exists() {
	command -v "$1" >/dev/null 2>&1
}

if command_exists sudo; then
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

package_installed() {
	local manager="$1"
	local package="$2"

	case "$manager" in
		apt)
			dpkg -s "$package" >/dev/null 2>&1
			;;
		dnf)
			rpm -q "$package" >/dev/null 2>&1
			;;
		pacman)
			pacman -Q "$package" >/dev/null 2>&1
			;;
		zypper)
			rpm -q "$package" >/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

install_repo_package_if_available() {
	local manager="$1"
	local package="$2"
	local label="$3"

	if ! package_exists "$manager" "$package"; then
		log_warn "$package package not found in $manager repositories"
		return 1
	fi

	log_info "Found $package package, installing"
	if run_pkg_install "$manager" "$package"; then
		log_info "$label installed from package manager"
		return 0
	fi

	log_warn "$package package install failed"
	return 1
}

choose_first_available_package() {
	local manager="$1"
	local label="$2"
	shift 2

	local candidate
	for candidate in "$@"; do
		if package_exists "$manager" "$candidate"; then
			echo "$candidate"
			return 0
		fi
	done

	die "Could not find a package for $label in $manager repositories. Tried: $*"
}

choose_latest_pacman_wlroots_package() {
	if package_exists pacman wlroots; then
		echo "wlroots"
		return 0
	fi

	local candidate
	local latest=""
	local latest_minor=-1

	while IFS= read -r candidate; do
		if [[ "$candidate" =~ ^wlroots0\.([0-9]+)$ ]]; then
			local minor_version="${BASH_REMATCH[1]}"
			if (( minor_version > latest_minor )); then
				latest_minor="$minor_version"
				latest="$candidate"
			fi
		fi
	done < <(pacman -Ssq '^wlroots0\.[0-9]+$' 2>/dev/null || true)

	if [[ -n "$latest" ]]; then
		echo "$latest"
		return 0
	fi

	die "Could not find a wlroots package in pacman repositories (expected wlroots or wlroots0.x)."
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

install_optional_packages() {
	local manager="$1"
	shift

	local package
	local available_packages=()
	local missing_packages=()

	for package in "$@"; do
		if package_exists "$manager" "$package"; then
			available_packages+=("$package")
		else
			missing_packages+=("$package")
		fi
	done

	if ((${#available_packages[@]} > 0)); then
		log_info "Installing optional packages: ${available_packages[*]}"
		run_pkg_install "$manager" "${available_packages[@]}"
	fi

	if ((${#missing_packages[@]} > 0)); then
		log_warn "Optional packages not found in $manager repositories: ${missing_packages[*]}"
	fi
}

try_install_mangowc_aur() {
	if try_install_aur_package mangowc-git; then
		return 0
	fi

	return 1
}

try_install_aur_package() {
	local package="$1"

	if command_exists yay; then
		log_info "Trying AUR package $package via yay"
		yay -S --needed --noconfirm "$package"
		return $?
	fi

	if command_exists paru; then
		log_info "Trying AUR package $package via paru"
		paru -S --needed --noconfirm "$package"
		return $?
	fi

	return 1
}

install_noctalia_manual_release() {
	local target_dir="$HOME/.config/quickshell/noctalia-shell"
	local release_url="https://github.com/noctalia-dev/noctalia-shell/releases/latest/download/noctalia-latest.tar.gz"

	if ! command_exists curl; then
		die "curl is required for manual Noctalia installation"
	fi

	if ! command_exists tar; then
		die "tar is required for manual Noctalia installation"
	fi

	log_info "Installing Noctalia shell manually to $target_dir"
	mkdir -p "$target_dir"
	curl -fsSL "$release_url" | tar -xz --strip-components=1 -C "$target_dir"
	log_info "Noctalia shell installed to $target_dir"
}

install_noctalia_from_repo() {
	local repo_url="$1"
	local target_dir="$HOME/.config/quickshell/noctalia-shell"

	log_info "Installing Noctalia shell from source repo: $repo_url"
	rm -rf "$target_dir"
	git clone --depth=1 "$repo_url" "$target_dir"
	log_info "Noctalia shell cloned to $target_dir"
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
			install_optional_packages "$manager" \
				libdisplay-info-dev libliftoff-dev hwdata libpcre2-dev libscenefx-dev
			;;
		dnf)
			run_pkg_install "$manager" \
				@development-tools git meson ninja-build pkgconf-pkg-config cmake curl \
				wayland-devel wayland-protocols-devel libxkbcommon-devel pixman-devel \
				libdrm-devel libinput-devel libxcb-devel xcb-util-devel \
				xcb-util-wm-devel xcb-util-errors-devel seatd-devel cairo-devel \
				pango-devel pam-devel xorg-x11-server-Xwayland mate-polkit
			install_optional_packages "$manager" \
				libdisplay-info-devel libliftoff-devel hwdata pcre2-devel scenefx-devel
			;;
		pacman)
			local wlroots_pkg
			local libseat_pkg
			wlroots_pkg="$(choose_latest_pacman_wlroots_package)"
			libseat_pkg="$(choose_first_available_package "$manager" "libseat" libseat seatd)"
			log_info "Using wlroots package: $wlroots_pkg"
			log_info "Using libseat package: $libseat_pkg"

			run_pkg_install "$manager" \
				base-devel git meson ninja pkgconf cmake curl wayland \
				wayland-protocols "$wlroots_pkg" xorg-xwayland libxkbcommon pixman libdrm \
				libinput libxcb xcb-util xcb-util-wm xcb-util-errors "$libseat_pkg" cairo \
				pango pam mate-polkit
			install_optional_packages "$manager" \
				libdisplay-info libliftoff hwdata pcre2 scenefx scenefx-git
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
			install_optional_packages "$manager" \
				libdisplay-info-devel libliftoff-devel hwdata pcre2-devel scenefx-devel
			;;
		*)
			die "Unsupported package manager: $manager"
			;;
	esac
}

detect_pkg_manager() {
	local manager
	for manager in apt dnf pacman zypper; do
		case "$manager" in
			apt)
				if command_exists apt-get; then
					echo "$manager"
					return
				fi
				;;
			dnf|pacman|zypper)
				if command_exists "$manager"; then
					echo "$manager"
					return
				fi
				;;
		esac
	done

	echo ""
}

try_install_mangowc_package() {
	local manager="$1"
	ensure_pkg_metadata "$manager"
	install_repo_package_if_available "$manager" "mangowc" "MangoWC"
}

build_mangowc_from_source() {
	local repo_url="$1"
	local tmp_dir
	local repo_dir
	tmp_dir="$(mktemp -d)"
	repo_dir="$tmp_dir/mangowc"
	log_info "Building MangoWC from source: $repo_url"
	git clone --depth=1 "$repo_url" "$repo_dir"
	(
		cd "$repo_dir"
		meson setup build
		ninja -C build
		$SUDO ninja -C build install
	)
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

	if [[ "$manager" == "pacman" ]]; then
		if try_install_mangowc_aur; then
			log_info "MangoWC installed from AUR package"
			return
		fi
		log_warn "Could not install mangowc-git via AUR helper"
	fi

	if [[ -z "$MANGOWC_REPO" ]]; then
		die "Could not install mangowc from package manager/AUR. Set MANGOWC_REPO to a valid git URL to build from source."
	fi

	build_mangowc_from_source "$MANGOWC_REPO"
}

install_config() {
	step "Installing config.conf"
	log_info "Installing config.conf to $CONFIG_DEST_FILE"
	mkdir -p "$CONFIG_DEST_DIR"
	install -m 644 "$CONFIG_SOURCE" "$CONFIG_DEST_FILE"
}

run_post_install_checks() {
	local manager="$1"
	step "Running post-install checks"

	local failures=0
	local noctalia_manual_dir="$HOME/.config/quickshell/noctalia-shell"

	if command_exists mangowc || command_exists mango; then
		log_info "MangoWC binary check passed"
	else
		log_error "MangoWC binary not found (expected 'mangowc' or 'mango' in PATH)"
		failures=$((failures + 1))
	fi

	if [[ -f "$CONFIG_DEST_FILE" ]]; then
		log_info "Mango config check passed: $CONFIG_DEST_FILE"
	else
		log_error "Mango config check failed: missing $CONFIG_DEST_FILE"
		failures=$((failures + 1))
	fi

	if command_exists noctalia-shell; then
		log_info "Noctalia shell binary check passed"
	elif package_installed "$manager" noctalia-shell; then
		log_info "Noctalia package check passed"
	elif [[ -d "$noctalia_manual_dir" ]]; then
		if command_exists qs; then
			log_info "Noctalia manual install check passed: $noctalia_manual_dir"
			log_info "Launch with: qs -p $noctalia_manual_dir"
		else
			log_warn "Noctalia files found at $noctalia_manual_dir, but 'qs' is not installed"
		fi
	else
		log_warn "Noctalia shell was not detected in PATH or manual install directory"
	fi

	if ((failures > 0)); then
		die "Post-install checks failed ($failures issue(s))."
	fi

	log_info "Post-install checks completed"
}

setup_noctalia() {
	local manager="$1"
	step "Setting up Noctalia"
	ensure_pkg_metadata "$manager"

	if install_repo_package_if_available "$manager" "noctalia-shell" "Noctalia shell"; then
		return
	fi

	if [[ "$manager" == "pacman" ]]; then
		if try_install_aur_package noctalia-shell || try_install_aur_package noctalia-shell-git; then
			log_info "Noctalia shell installed from AUR package"
			return
		fi
		log_warn "Could not install noctalia-shell via AUR helper"
	fi

	if [[ -n "$NOCTALIA_REPO" ]]; then
		install_noctalia_from_repo "$NOCTALIA_REPO"
		return
	fi

	install_noctalia_manual_release
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
	run_post_install_checks "$manager"

	printf '\n'
	log_info "All tasks completed successfully"
}

main "$@"
