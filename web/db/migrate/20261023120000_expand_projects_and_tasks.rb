# frozen_string_literal: true

# Completes Projects and Tasks: task detail (comments, checklist, dependencies,
# time, files, labels, recurrence, blocked reason), project dates, members,
# goal link and templates, board ordering, and in-app notifications.
#
# tasks.project_id was a string that held a project's integer id, with no key
# behind it. It becomes a real integer reference. Ids that point at no project
# in the task's own workspace (stray text, deleted or foreign projects) are
# cleared first: those tasks stay, as unfiled work, instead of failing the change.
class ExpandProjectsAndTasks < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute(<<~SQL.squish)
        UPDATE tasks SET project_id = NULL
        WHERE project_id IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM projects p
          WHERE p.id = CAST(tasks.project_id AS INTEGER) AND p.tenant_id = tasks.tenant_id
        )
      SQL
      change_column :tasks, :project_id, :bigint
      add_foreign_key :tasks, :projects
    end

    add_column :projects, :start_on, :date
    add_column :projects, :goal_id, :bigint
    add_index :projects, :goal_id

    add_column :tasks, :start_on, :date
    add_column :tasks, :blocked_reason, :text
    add_column :tasks, :position, :integer
    add_column :tasks, :labels, :text
    add_column :tasks, :recurrence, :string
    add_column :tasks, :next_spawned_at, :datetime
    add_column :tasks, :estimate_minutes, :integer
    add_index :tasks, %i[tenant_id due_on]

    create_table :task_comments do |t|
      t.string :tenant_id, null: false
      t.references :task, null: false, foreign_key: true
      t.bigint :user_id
      t.text :body, null: false
      t.timestamps
    end
    add_index :task_comments, %i[tenant_id task_id created_at]

    create_table :task_checklist_items do |t|
      t.string :tenant_id, null: false
      t.references :task, null: false, foreign_key: true
      t.string :title, null: false
      t.boolean :done, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end

    create_table :task_dependencies do |t|
      t.string :tenant_id, null: false
      t.references :task, null: false, foreign_key: true
      t.bigint :blocker_id, null: false
      t.timestamps
    end
    add_index :task_dependencies, %i[task_id blocker_id], unique: true
    add_index :task_dependencies, :blocker_id
    add_foreign_key :task_dependencies, :tasks, column: :blocker_id

    create_table :task_time_entries do |t|
      t.string :tenant_id, null: false
      t.references :task, null: false, foreign_key: true
      t.bigint :user_id
      t.integer :minutes, null: false
      t.date :logged_on, null: false
      t.string :note
      t.timestamps
    end

    create_table :task_attachments do |t|
      t.string :tenant_id, null: false
      t.references :task, null: false, foreign_key: true
      t.bigint :user_id
      t.string :filename, null: false
      t.string :content_type, null: false
      t.integer :byte_size, null: false
      t.binary :body, null: false
      t.timestamps
    end

    create_table :project_members do |t|
      t.string :tenant_id, null: false
      t.references :project, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.timestamps
    end
    add_index :project_members, %i[project_id user_id], unique: true

    create_table :project_templates do |t|
      t.string :tenant_id, null: false
      t.string :name, null: false
      t.text :description
      t.text :payload, null: false
      t.bigint :created_by_id
      t.timestamps
    end

    create_table :notifications do |t|
      t.string :tenant_id, null: false
      t.bigint :user_id, null: false
      t.string :kind, null: false
      t.string :title, null: false
      t.text :body
      t.string :url
      t.string :dedupe_key
      t.datetime :read_at
      t.timestamps
    end
    add_index :notifications, %i[user_id read_at created_at]
    add_index :notifications, %i[user_id dedupe_key], unique: true
  end

  def down
    drop_table :notifications
    drop_table :project_templates
    drop_table :project_members
    drop_table :task_attachments
    drop_table :task_time_entries
    drop_table :task_dependencies
    drop_table :task_checklist_items
    drop_table :task_comments
    remove_index :tasks, %i[tenant_id due_on]
    remove_column :tasks, :estimate_minutes
    remove_column :tasks, :next_spawned_at
    remove_column :tasks, :recurrence
    remove_column :tasks, :labels
    remove_column :tasks, :position
    remove_column :tasks, :blocked_reason
    remove_column :tasks, :start_on
    remove_index :projects, :goal_id
    remove_column :projects, :goal_id
    remove_column :projects, :start_on
    remove_foreign_key :tasks, :projects
    change_column :tasks, :project_id, :string
  end
end
