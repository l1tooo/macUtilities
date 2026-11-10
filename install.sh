#!/bin/zsh
# Установка и обновление утилит из macUtilities одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/l1tooo/macUtilities/main/install.sh | zsh
#
# По умолчанию ставит Chelka. Другие варианты:
#   ... | zsh -s -- DockToggle        только DockToggle
#   ... | zsh -s -- all               все утилиты
#
# Что делает: при необходимости ставит инструменты разработчика Apple, скачивает исходники
# в ~/macUtilities (или обновляет их), собирает программу у тебя на Маке, кладёт в
# ~/Applications и запускает. Повторный запуск той же команды — обновление.
#
# Для проверки (без установки): MACUTILS_REPO=<адрес git> MACUTILS_DIR=<папка> MACUTILS_BUILD_ONLY=1

# Всё внутри функции: если загрузка оборвётся на середине, недокачанный скрипт ничего не выполнит.
macutils_install() {
  emulate -L zsh
  setopt err_return pipe_fail

  local repo="${MACUTILS_REPO:-https://github.com/l1tooo/macUtilities.git}"
  local dir="${MACUTILS_DIR:-$HOME/macUtilities}"
  local all=(Chelka DockToggle)
  local -A min_macos=(Chelka 14 DockToggle 13)
  local name mode log waited=0

  say()  { print -P "%F{cyan}▸%f $*"; }
  ok()   { print -P "%F{green}✓%f $*"; }
  fail() { print -P "%F{red}✗%f $*" >&2; return 1; }

  # Какие утилиты ставить.
  local wanted=()
  if (( $# == 0 )); then
    wanted=(Chelka)
  elif [[ "$1" == "all" ]]; then
    wanted=($all)
  else
    for name in "$@"; do
      (( ${all[(Ie)$name]} )) || { fail "Нет такой утилиты: $name. Есть: ${(j:, :)all}"; return 1; }
      wanted+=("$name")
    done
  fi

  # Версия macOS.
  local macos="$(sw_vers -productVersion)"
  local major="${macos%%.*}"
  for name in $wanted; do
    if (( major < min_macos[$name] )); then
      fail "$name нужна macOS ${min_macos[$name]} или новее, а у тебя $macos."
      return 1
    fi
  done

  # Инструменты разработчика Apple (swiftc и git). Если их нет — macOS покажет окно установки.
  if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    say "Нужны инструменты разработчика Apple. Сейчас откроется окно: нажми «Установить» и дождись конца (обычно 5–15 минут)."
    xcode-select --install >/dev/null 2>&1 || true
    until xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; do
      sleep 10
      (( waited += 10 ))
      if (( waited >= 3600 )); then
        fail "Инструменты так и не установились. Поставь их командой xcode-select --install и запусти установку снова."
        return 1
      fi
    done
    ok "Инструменты разработчика установлены."
  fi

  # Исходники: скачать или обновить.
  if [[ -d "$dir/.git" ]]; then
    say "Обновляю исходники в $dir"
    git -C "$dir" pull --ff-only --quiet || {
      fail "Не получилось обновить $dir: похоже, там есть свои правки. Убери их (или удали папку) и запусти снова."
      return 1
    }
  elif [[ -e "$dir" ]]; then
    fail "Папка $dir уже есть, но это не копия macUtilities. Переименуй её и запусти снова."
    return 1
  else
    say "Скачиваю исходники в $dir"
    git clone --quiet "$repo" "$dir"
  fi
  ok "Исходники: $(git -C "$dir" log -1 --format='%h от %cd' --date=short)"

  # Сборка и установка.
  for name in $wanted; do
    say "Собираю $name (около минуты)…"
    mode=install
    [[ -n "${MACUTILS_BUILD_ONLY:-}" ]] && mode=""
    # Вывод сборки показываем только при ошибке.
    if ! log="$("$dir/$name/build.sh" $mode 2>&1)"; then
      print -r -- "$log" >&2
      fail "$name не собралась. Пришли текст выше автору."
      return 1
    fi
    if [[ -z "$mode" ]]; then
      ok "$name собрана: $dir/$name/build/$name.app"
    else
      open "$HOME/Applications/$name.app"
      ok "$name установлена в ~/Applications и запущена."
    fi
  done

  print
  for name in $wanted; do
    case "$name" in
      Chelka)
        print "Chelka: наведи мышь на вырез у камеры (на Маке без выреза — на середину строки меню)."
        print "  Разрешения macOS спросит сама: кнопки ⏮ ⏯ ⏭ — «Универсальный доступ», запись экрана — «Запись экрана»"
        print "  (после неё Chelka нужно перезапустить: правый клик по панели → «Выйти» и открыть снова)."
        ;;
      DockToggle)
        print "DockToggle: значок в строке меню. Дай ему «Универсальный доступ» в Настройках → Конфиденциальность."
        ;;
    esac
  done
  print "Обновить потом: запусти ту же команду ещё раз. После обновления разрешения, возможно, придётся выдать заново."
}

macutils_install "$@"
