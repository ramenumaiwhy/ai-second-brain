#!/usr/bin/env python3
"""
ChatGPT会話履歴をObsidian用Markdownに変換するスクリプト
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


def sanitize_filename(name: str) -> str:
    """ファイル名に使えない文字を除去"""
    # ファイル名に使えない文字を置換
    name = re.sub(r'[<>:"/\\|?*]', '', name)
    name = re.sub(r'[\x00-\x1f\x7f]', '', name)
    # 空白を_に
    name = re.sub(r'\s+', '_', name)
    # 長すぎる場合は切る
    if len(name) > 50:
        name = name[:50]
    name = name.strip('.')
    return name if name and name not in ('.', '..') else 'untitled'


def extract_messages(conversation: dict) -> list[dict]:
    """会話からメッセージを時系列で抽出"""
    mapping = conversation.get('mapping', {})
    messages = []

    for msg_id, msg_data in mapping.items():
        message = msg_data.get('message')
        if not message:
            continue

        content = message.get('content', {})
        parts = content.get('parts', [])

        if not parts:
            continue

        author = message.get('author', {}).get('role', 'unknown')
        if author not in ['user', 'assistant']:
            continue

        # テキスト部分だけ抽出（画像などは除外）
        text_parts = [p for p in parts if isinstance(p, str)]
        if not text_parts:
            continue

        text = '\n'.join(text_parts)
        create_time = message.get('create_time') or 0

        messages.append({
            'author': author,
            'text': text,
            'create_time': create_time
        })

    # 時系列でソート
    messages.sort(key=lambda x: x['create_time'])
    return messages


def convert_to_markdown(conversation: dict) -> str:
    """1つの会話をMarkdownに変換"""
    title = conversation.get('title', 'Untitled')
    create_time = conversation.get('create_time', 0)

    # 日付フォーマット
    if create_time:
        date_str = datetime.fromtimestamp(create_time).strftime('%Y-%m-%d')
    else:
        date_str = 'unknown'

    messages = extract_messages(conversation)

    if not messages:
        return None

    # YAMLエスケープ: ダブルクォート・バックスラッシュ・改行を処理
    escaped_title = json.dumps(title)[1:-1]  # json.dumps で安全にエスケープし前後の " を除去
    safe_heading = title.replace('\n', ' ').replace('\r', '')

    # Markdown生成
    lines = [
        '---',
        f'date: {date_str}',
        f'title: "{escaped_title}"',
        'source: ChatGPT',
        'tags: [chatgpt]',
        '---',
        '',
        f'# {safe_heading}',
        ''
    ]

    q_count = 0
    a_count = 0

    for msg in messages:
        if msg['author'] == 'user':
            q_count += 1
            lines.append(f'## Q{q_count}')
            lines.append(msg['text'])
            lines.append('')
        else:
            a_count += 1
            lines.append(f'## A{a_count}')
            lines.append(msg['text'])
            lines.append('')

    return '\n'.join(lines)


def main():
    # パス設定
    home = Path.home()
    input_file = home / 'Downloads/chatgpt_export/conversations.json'
    output_dir = Path(os.environ.get('SECOND_BRAIN_DIR') or '')
    if not output_dir or not output_dir.is_dir():
        print('Error: SECOND_BRAIN_DIR is not set or does not exist.', file=sys.stderr)
        sys.exit(1)

    # 出力ディレクトリ作成
    output_dir.mkdir(parents=True, exist_ok=True)

    # JSON読み込み
    print(f'読み込み中: {input_file}')
    with open(input_file, 'r', encoding='utf-8', errors='replace') as f:
        conversations = json.load(f)

    print(f'会話数: {len(conversations)}件')

    # 変換
    success_count = 0
    skip_count = 0
    filename_counts = {}  # 同名ファイル対策

    for i, conv in enumerate(conversations):
        title = conv.get('title', 'Untitled')
        create_time = conv.get('create_time', 0)

        # Markdown変換
        md_content = convert_to_markdown(conv)
        if not md_content:
            skip_count += 1
            continue

        # ファイル名生成
        if create_time:
            date_prefix = datetime.fromtimestamp(create_time).strftime('%Y-%m-%d')
        else:
            date_prefix = 'unknown'

        safe_title = sanitize_filename(title)
        base_filename = f'{date_prefix}_{safe_title}'

        # 同名ファイルがある場合は連番付与
        if base_filename in filename_counts:
            filename_counts[base_filename] += 1
            filename = f'{base_filename}_{filename_counts[base_filename]}.md'
        else:
            filename_counts[base_filename] = 0
            filename = f'{base_filename}.md'

        # 保存
        output_path = output_dir / filename
        with open(output_path, 'w', encoding='utf-8') as f:
            f.write(md_content)

        success_count += 1

        # 進捗表示
        if (i + 1) % 100 == 0:
            print(f'  {i + 1}/{len(conversations)} 完了...')

    print(f'\n完了!')
    print(f'  成功: {success_count}件')
    print(f'  スキップ: {skip_count}件（メッセージなし）')
    print(f'  出力先: {output_dir}')


if __name__ == '__main__':
    main()
