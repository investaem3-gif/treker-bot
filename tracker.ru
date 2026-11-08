# Трекер дня: в 8:00 по Москве задаёт вопросы из листа "Вопросы"
# и записывает ваши ответы в лист "Данные".
# Запускается каждые 5 минут через GitHub Actions.
# Своё состояние (на каком вопросе остановились) хранит в листе "Состояние".

import os
import json
import datetime as dt
from zoneinfo import ZoneInfo

import requests
import gspread

# --- Секреты (берутся из GitHub Secrets) ---
TOKEN = os.environ["TG_TOKEN"]
OWNER = int(os.environ["OWNER_ID"])
SHEET_ID = os.environ["SHEET_ID"]
CREDS = json.loads(os.environ["GOOGLE_CREDENTIALS"])

ASK_HOUR = 8  # во сколько по Москве задавать вопросы
DAYS = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
API = f"https://api.telegram.org/bot{TOKEN}"


def tg(method, **params):
    r = requests.post(f"{API}/{method}", json=params, timeout=30)
    r.raise_for_status()
    return r.json()["result"]


# --- Подключаемся к таблице ---
gc = gspread.service_account_from_dict(CREDS)
book = gc.open_by_key(SHEET_ID)
data_ws = book.worksheet("Данные")
q_ws = book.worksheet("Вопросы")

KEYS = ["last_update_id", "asked_date", "idx", "answers", "questions"]
DEFAULTS = {"last_update_id": "0", "asked_date": "", "idx": "0",
            "answers": "[]", "questions": "[]"}

try:
    st_ws = book.worksheet("Состояние")
except gspread.WorksheetNotFound:
    st_ws = book.add_worksheet("Состояние", rows=10, cols=2)

# --- Читаем состояние ---
rows = st_ws.get_all_values()
state = dict(DEFAULTS)
for r in rows:
    if r and r[0] in KEYS and len(r) > 1 and r[1] != "":
        state[r[0]] = r[1]

now = dt.datetime.now(ZoneInfo("Europe/Moscow"))
today_tag = "D:" + now.date().isoformat()

# --- 1. Обрабатываем новые ответы ---
updates = tg("getUpdates", offset=int(state["last_update_id"]) + 1, timeout=0)
for u in updates:
    state["last_update_id"] = str(u["update_id"])
    m = u.get("message")
    if not m or m.get("from", {}).get("id") != OWNER or "text" not in m:
        continue
    questions = json.loads(state["questions"])
    idx = int(state["idx"])
    if idx >= len(questions):
        continue  # сейчас нет активного опроса
    answers = json.loads(state["answers"])
    answers.append(m["text"].strip())
    idx += 1
    if idx < len(questions):
        tg("sendMessage", chat_id=OWNER, text=questions[idx])
    else:
        row = [state["asked_date"][2:]] + answers
        data_ws.append_row(row, value_input_option="USER_ENTERED")
        tg("sendMessage", chat_id=OWNER, text="Записано ✅")
    state["idx"] = str(idx)
    state["answers"] = json.dumps(answers, ensure_ascii=False)

# --- 2. Если пора, задаём вопросы нового дня ---
if now.hour >= ASK_HOUR and state["asked_date"] != today_tag:
    day = DAYS[now.weekday()]
    questions = []
    for r in q_ws.get_all_values():
        if r and r[0].strip().lower() == day:
            questions = [q.strip() for q in r[1:] if q.strip()]
            break
    state["asked_date"] = today_tag
    state["idx"] = "0"
    state["answers"] = "[]"
    state["questions"] = json.dumps(questions, ensure_ascii=False)
    if questions:
        tg("sendMessage", chat_id=OWNER, text="Доброе утро! Пара вопросов:")
        tg("sendMessage", chat_id=OWNER, text=questions[0])

# --- Сохраняем состояние ---
st_ws.update(values=[[k, str(state[k])] for k in KEYS], range_name="A1:B5")
print("Готово")
