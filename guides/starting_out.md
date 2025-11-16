# Comprehensive Guide to Dataloader

## Table of Contents
1. What is Dataloader?
2. Why Use Dataloader?
3. Core Concepts
4. Basic Usage - Step by Step
5. KV Source (Key-Value)
6. Ecto Source
7. Loading Associations
8. Custom Queries and Filtering
9. Custom Batch Functions
10. Pagination
11. Error Handling Policies
12. Common Patterns & Best Practices
13. Troubleshooting

---

## 1. What is Dataloader?

Dataloader is an Elixir library that solves the "N+1 query problem" by efficiently
loading data in batches. Instead of making separate database queries for each item,
it collects all the requests and executes them together in optimized batches.

Think of it like this:
- WITHOUT Dataloader: "Get user 1. Get user 2. Get user 3." (3 queries)
- WITH Dataloader: "Get users 1, 2, and 3." (1 query)

---

## 2. Why Use Dataloader?

### The N+1 Problem Example

Imagine you have 100 blog posts and want to display each post with its author:

```elixir
# BAD: N+1 queries (1 for posts + 100 for authors = 101 queries!)
posts = Repo.all(Post)
Enum.map(posts, fn post ->
  author = Repo.get(User, post.user_id)  # Query for EACH post!
  "#{post.title} by #{author.name}"
end)
```

With Dataloader:
```elixir
# GOOD: 2 queries total (1 for posts + 1 for all authors)
# Dataloader batches all author lookups into a single query
```

### When to Use Dataloader

**Use Dataloader when:**
- Building GraphQL APIs (it was designed for this!)
- Rendering templates with associated data
- Processing lists where each item needs related data
- You have nested data requirements

L **Don't use Dataloader when:**
- Simple one-off queries (just use Ecto.Repo.get)
- You can use Ecto.Repo.preload (it's simpler)
- Single item lookups

---

## 3. Core Concepts

### The Dataloader Workflow (4 Steps)

```
1. CREATE   ? Set up a loader with sources
2. LOAD     ? Tell it what data you'll need
3. RUN      ? Execute all batches concurrently
4. GET      ? Retrieve the loaded data
```

### Key Terms

**Dataloader**: The main struct that manages everything. Think of it as a coordinator.

**Source**: A strategy for loading data. Two built-in types:
  - `Dataloader.KV` - For custom key-value loading (API calls, cache, etc.)
  - `Dataloader.Ecto` - For loading from database via Ecto

**Source Name**: A label you give to each source (e.g., `:db`, `:accounts`, `:api`)

**Batch Key**: What type of data to load (e.g., `User`, `Post`, `:organization`)

**Batch**: A collection of IDs or items to load together

---

## 4. Basic Usage - Step by Step

### Example: Loading Organizations by ID

```elixir
# STEP 1: CREATE - Set up the dataloader
source = Dataloader.Ecto.new(MyApp.Repo)
loader = Dataloader.new() |> Dataloader.add_source(:db, source)

# STEP 2: LOAD - Queue up what you need
loader =
  loader
  |> Dataloader.load(:db, Organization, 1)           # Load org with id=1
  |> Dataloader.load_many(:db, Organization, [4, 9]) # Load orgs with ids 4,9

# At this point, NO queries have run yet! We're just recording what we need.

# STEP 3: RUN - Execute all batches
loader = Dataloader.run(loader)

# NOW the query runs! It fetches organizations with ids [1, 4, 9] in ONE query:
# SELECT * FROM organizations WHERE id IN (1, 4, 9)

# STEP 4: GET - Retrieve the results
org_1 = Dataloader.get(loader, :db, Organization, 1)
orgs_many = Dataloader.get_many(loader, :db, Organization, [1, 4])
```

### Understanding the Flow

```elixir
loader = Dataloader.new()
# loader = %Dataloader{sources: %{}}

loader = Dataloader.add_source(loader, :db, source)
# loader = %Dataloader{sources: %{db: source}}

loader = Dataloader.load(loader, :db, Organization, 1)
# Records: "I need Organization with id=1 from :db source"
# Still NO query executed!

loader = Dataloader.load(loader, :db, Organization, 4)
# Records: "I also need Organization with id=4"
# Dataloader thinks: "Oh, both are Organizations, I'll batch them together"

loader = Dataloader.run(loader)
# Executes: SELECT * FROM organizations WHERE id IN (1, 4)
# Stores results internally

result = Dataloader.get(loader, :db, Organization, 1)
# Returns the cached result (no new query)
```

---

## 5. KV Source (Key-Value)

Use KV source when loading data from non-database sources like APIs, caches,
external services, or custom data structures.

### Basic KV Example

```elixir
# Your data
@users [
  %{id: 1, name: "Alice"},
  %{id: 2, name: "Bob"},
  %{id: 3, name: "Charlie"}
]

# Define how to load data
def load_users(_batch_key, user_ids) do
  # user_ids is a MapSet of IDs to load
  # Must return a map of {id => value}

  for id <- user_ids, into: %{} do
    user = Enum.find(@users, fn u -> u.id == id end)
    {id, user}
  end
end

# Create the source
source = Dataloader.KV.new(&load_users/2)

# Use it
loader =
  Dataloader.new()
  |> Dataloader.add_source(:users, source)
  |> Dataloader.load(:users, :user, 1)
  |> Dataloader.load(:users, :user, 2)
  |> Dataloader.run()

alice = Dataloader.get(loader, :users, :user, 1)
# => %{id: 1, name: "Alice"}
```

### KV with Different Batch Keys

```elixir
def load_data(batch_key, ids) do
  case batch_key do
    :users ->
      # Load users
      fetch_users(ids)

    :posts ->
      # Load posts
      fetch_posts(ids)

    :comments ->
      # Load comments
      fetch_comments(ids)
  end
end

source = Dataloader.KV.new(&load_data/2)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:api, source)
  |> Dataloader.load(:api, :users, 1)      # Different batch key
  |> Dataloader.load(:api, :posts, 10)     # Different batch key
  |> Dataloader.run()
```

### KV Options

```elixir
source = Dataloader.KV.new(&load_data/2,
  max_concurrency: 4,      # Max parallel tasks (default: 2x CPU cores)
  timeout: 10_000,         # Timeout per batch in ms (default: 30_000)
  async?: false            # Run synchronously (default: true)
)
```

---

## 6. Ecto Source

The Ecto source is the most common use case - loading data from your database.

### Basic Ecto Usage

```elixir
# Setup
source = Dataloader.Ecto.new(MyApp.Repo)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, source)

# Loading by primary key (like Repo.get)
loader =
  loader
  |> Dataloader.load(:db, User, 1)              # Single user
  |> Dataloader.load_many(:db, User, [2, 3, 4]) # Multiple users
  |> Dataloader.run()

user = Dataloader.get(loader, :db, User, 1)
# Executes: SELECT * FROM users WHERE id IN (1, 2, 3, 4)
```

### Loading by Column (Not Primary Key)

When querying by a non-primary key column, you MUST specify cardinality:

```elixir
# Cardinality :one - Returns single result or nil
loader =
  loader
  |> Dataloader.load(:db, {:one, User}, email: "alice@example.com")
  |> Dataloader.run()

user = Dataloader.get(loader, :db, {:one, User}, email: "alice@example.com")

# Cardinality :many - Returns list of results
loader =
  loader
  |> Dataloader.load(:db, {:many, User}, role: "admin")
  |> Dataloader.run()

admins = Dataloader.get(loader, {:many, User}, role: "admin")
# => [%User{}, %User{}, ...]
```

**Why cardinality?**
- Primary key = always unique, so we know it's one result
- Other columns = might have multiple matches, you must specify :one or :many

### String IDs

Dataloader handles type conversion:

```elixir
# Works with string IDs too!
loader =
  loader
  |> Dataloader.load(:db, User, "123")  # String ID
  |> Dataloader.run()

user = Dataloader.get(loader, :db, User, "123")
# Dataloader converts "123" to integer automatically
```

---

## 7. Loading Associations

One of Dataloader's superpowers is loading associations efficiently.

### Basic Association Loading

```elixir
# Schema
defmodule Post do
  schema "posts" do
    belongs_to :user, User
    belongs_to :organization, Organization
  end
end

# Load associations
post = Repo.get(Post, 1)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, Dataloader.Ecto.new(Repo))
  |> Dataloader.load(:db, :user, post)           # Load post's user
  |> Dataloader.load(:db, :organization, post)   # Load post's org
  |> Dataloader.run()

user = Dataloader.get(loader, :db, :user, post)
org = Dataloader.get(loader, :db, :organization, post)
```

### Batch Loading Associations

```elixir
posts = Repo.all(Post)  # 100 posts

loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, Dataloader.Ecto.new(Repo))
  |> Dataloader.load_many(:db, :user, posts)  # Load ALL post authors
  |> Dataloader.run()

# Single query: SELECT * FROM users WHERE id IN (...)
# Instead of 100 separate queries!

users = Dataloader.get_many(loader, :db, :user, posts)
```

### Has-Many Associations

```elixir
defmodule User do
  schema "users" do
    has_many :posts, Post
  end
end

user = Repo.get(User, 1)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, Dataloader.Ecto.new(Repo))
  |> Dataloader.load(:db, :posts, user)  # Load user's posts
  |> Dataloader.run()

posts = Dataloader.get(loader, :db, :posts, user)
# => [%Post{}, %Post{}, ...]
```

---

## 8. Custom Queries and Filtering

The `query/2` function lets you customize how data is loaded.

### Setting Up a Query Function

```elixir
defmodule MyApp.Accounts do
  def query(User, params) do
    # Customize User queries
    User
    |> apply_filters(params)
    |> apply_ordering(params)
  end

  def query(Organization, params) do
    # Customize Organization queries
    Organization
    |> where([o], o.active == true)
  end

  def query(queryable, _params) do
    # Default: no customization
    queryable
  end

  defp apply_filters(query, %{role: role}) do
    where(query, [u], u.role == ^role)
  end
  defp apply_filters(query, _), do: query

  defp apply_ordering(query, %{order_by: field}) do
    order_by(query, [u], asc: ^field)
  end
  defp apply_ordering(query, _), do: query
end

# Create source with query function
source = Dataloader.Ecto.new(Repo, query: &MyApp.Accounts.query/2)
```

### Using Parameters

```elixir
loader =
  Dataloader.new()
  |> Dataloader.add_source(:accounts, source)

  # Load with parameters
  |> Dataloader.load(:accounts, {User, %{order_by: :name}}, 1)
  |> Dataloader.load(:accounts, {User, %{role: "admin"}}, 2)

  # Parameters are passed to your query/2 function
  |> Dataloader.run()
```

### Default Parameters (Very Useful!)

```elixir
# Store current_user in default params
def create_loader(current_user) do
  source = Dataloader.Ecto.new(Repo,
    query: &MyApp.Accounts.query/2,
    default_params: %{current_user: current_user}
  )

  Dataloader.new()
  |> Dataloader.add_source(:accounts, source)
end

# Your query function can access current_user
def query(Organization, %{current_user: user}) do
  # Only load organizations the user has access to
  from o in Organization,
    join: m in assoc(o, :memberships),
    where: m.user_id == ^user.id
end

# Usage
loader = create_loader(current_user)
|> Dataloader.load(:accounts, Organization, 1)
|> Dataloader.run()

# Automatically scoped to user's accessible organizations!
```

### Three-Tuple for Additional Params

```elixir
# Override default params with specific params
loader
|> Dataloader.load(:accounts, {:one, User, %{include_deleted: true}}, id: 1)
|> Dataloader.run()

# Params are merged: default_params + %{include_deleted: true}
```

---

## 9. Custom Batch Functions

For advanced use cases, you can override how batches are run.

### Example: Counting Related Records

```elixir
defmodule MyApp.Posts do
  def query(Post, params) do
    Post
    |> where([p], p.published == true)
  end

  def query(queryable, _), do: queryable

  # Custom batch function to count posts per user
  def run_batch(_queryable, query, :post_count, users, repo_opts) do
    user_ids = Enum.map(users, & &1.id)

    counts =
      query
      |> where([p], p.user_id in ^user_ids)
      |> group_by([p], p.user_id)
      |> select([p], {p.user_id, count("*")})
      |> Repo.all(repo_opts)
      |> Map.new()

    # MUST return a list in the same order as users
    for %{id: id} <- users do
      Map.get(counts, id, 0)
    end
  end

  # Fallback to default behavior
  def run_batch(queryable, query, col, inputs, repo_opts) do
    Dataloader.Ecto.run_batch(Repo, queryable, query, col, inputs, repo_opts)
  end
end

# Setup
source = Dataloader.Ecto.new(Repo,
  query: &MyApp.Posts.query/2,
  run_batch: &MyApp.Posts.run_batch/5
)

# Usage
users = [%User{id: 1}, %User{id: 2}]

loader =
  Dataloader.new()
  |> Dataloader.add_source(:posts, source)
  |> Dataloader.load(:posts, {:one, Post}, post_count: users)
  |> Dataloader.run()

count = Dataloader.get(loader, :posts, {:one, Post}, post_count: user1)
# => 5 (user has 5 posts)
```

---

## 10. Pagination

Pagination with Dataloader is all about controlling the number of results returned
using **`limit`** and **`offset`** (or cursors). These parameters are passed through
the batch key to your query function.

### Example Schema: Comments

For these examples, we'll use a Comment schema that belongs to Posts:

```elixir
defmodule Comment do
  schema "comments" do
    field :content, :string
    field :author_name, :string
    belongs_to :post, Post

    timestamps()
  end
end
```

Common scenario: Loading the most recent comments for blog posts.

### Core Concepts: LIMIT and OFFSET

**`limit`** - How many records to return (e.g., 10 comments per post)
**`offset`** - How many records to skip (e.g., skip first 10 for page 2)

The key insight: These parameters become part of your **batch key**, so Dataloader
can properly batch queries with the same limit/offset together.

### Understanding the Challenge

When you use Dataloader without pagination, it batches efficiently:
```elixir
# Efficient: Single query for all users
loader
|> Dataloader.load_many(:db, User, [1, 2, 3, 4, 5])
# SELECT * FROM users WHERE id IN (1,2,3,4,5)
```

With pagination, each limit/offset combination needs separate handling:
```elixir
# Less efficient: Different limits = different batches
loader
|> Dataloader.load(:db, {Comment, %{limit: 10}}, post_id: 1)
|> Dataloader.load(:db, {Comment, %{limit: 20}}, post_id: 2)
# Can't easily batch these together because they have different limits
```

### Basic LIMIT Usage

Start with the simplest case: limiting results for a query.

```elixir
defmodule MyApp.Content do
  # Handle limit parameter in your query function
  def query(Comment, %{limit: limit}) do
    Comment
    |> limit(^limit)
    |> order_by([c], desc: c.inserted_at)  # Most recent comments first
  end

  def query(queryable, _), do: queryable
end

# Setup
source = Dataloader.Ecto.new(Repo, query: &MyApp.Content.query/2)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:content, source)

# Load first 10 comments for a post - Notice the tuple format!
post = Repo.get(Post, 123)

loader =
  loader
  |> Dataloader.load(:content, {Comment, %{limit: 10}}, post_id: post.id)
  |> Dataloader.run()

# Get the limited results
comments = Dataloader.get(loader, :content, {Comment, %{limit: 10}}, post_id: post.id)
# => Returns max 10 most recent comments for this post
```

**Important:** The batch key MUST match exactly between load and get:
```elixir
# This works
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 1)
Dataloader.get(loader, :db, {Comment, %{limit: 10}}, post_id: 1)

# This FAILS - batch keys don't match!
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 1)
Dataloader.get(loader, :db, Comment, post_id: 1)  # Missing %{limit: 10}
```

### OFFSET and LIMIT Together (Page-Based Pagination)

Use both `offset` and `limit` to implement traditional page-based pagination.
This is useful for "Load more comments" functionality.

```elixir
defmodule MyApp.Content do
  # Pattern match on both offset and limit
  def query(Comment, %{offset: offset, limit: limit}) do
    Comment
    |> offset(^offset)
    |> limit(^limit)
    |> order_by([c], desc: c.inserted_at)
  end

  # Fallback when only limit is provided
  def query(Comment, %{limit: limit}) do
    Comment
    |> limit(^limit)
    |> order_by([c], desc: c.inserted_at)
  end

  def query(queryable, _), do: queryable
end

# Setup source
source = Dataloader.Ecto.new(Repo, query: &MyApp.Content.query/2)

loader = Dataloader.new()
  |> Dataloader.add_source(:content, source)

# Load multiple pages of comments for a post
post = Repo.get(Post, 123)

loader =
  loader
  |> Dataloader.load(:content, {Comment, %{offset: 0, limit: 10}}, post_id: post.id)   # First 10
  |> Dataloader.load(:content, {Comment, %{offset: 10, limit: 10}}, post_id: post.id)  # Next 10
  |> Dataloader.load(:content, {Comment, %{offset: 20, limit: 10}}, post_id: post.id)  # Next 10
  |> Dataloader.run()

# Get each page
first_10 = Dataloader.get(loader, :content, {Comment, %{offset: 0, limit: 10}}, post_id: post.id)
next_10 = Dataloader.get(loader, :content, {Comment, %{offset: 10, limit: 10}}, post_id: post.id)
more_10 = Dataloader.get(loader, :content, {Comment, %{offset: 20, limit: 10}}, post_id: post.id)

# Each page returns up to 10 comments
```

### Calculating Page Offsets

Helper function to calculate offset from page number:

```elixir
def page_to_offset(page_number, page_size) do
  (page_number - 1) * page_size
end

# Load page 3 of comments (10 per page)
post = Repo.get(Post, 123)
page = 3
page_size = 10
offset = page_to_offset(page, page_size)  # => 20

loader
|> Dataloader.load(:content, {Comment, %{offset: offset, limit: page_size}}, post_id: post.id)
|> Dataloader.run()

comments = Dataloader.get(loader, :content, {Comment, %{offset: offset, limit: page_size}}, post_id: post.id)
# => Comments 21-30 (most recent first)
```

### LIMIT with Cardinality

When using limit with queries by column (not primary key), specify cardinality:

```elixir
# Using :many cardinality with limit - Get comments by author
loader
|> Dataloader.load(:content, {{:many, Comment}, %{limit: 5}}, author_name: "Alice")
|> Dataloader.run()

comments = Dataloader.get(loader, :content, {{:many, Comment}, %{limit: 5}}, author_name: "Alice")
# => Returns up to 5 most recent comments by Alice

# Using :one cardinality with limit (returns single item or nil)
loader
|> Dataloader.load(:content, {{:one, Comment}, %{limit: 1}}, author_name: "Bob")
|> Dataloader.run()

comment = Dataloader.get(loader, :content, {{:one, Comment}, %{limit: 1}}, author_name: "Bob")
# => Returns Bob's most recent comment (or nil)
```

### LIMIT Per Association (Important Pattern)

Loading a limited number of items per parent (e.g., "first 10 comments for each post"):

```elixir
defmodule MyApp.Content do
  def query(Comment, %{limit: limit}) do
    Comment
    |> limit(^limit)
    |> order_by([c], desc: c.inserted_at)
  end

  def query(queryable, _), do: queryable
end

# Load first 10 comments for each post
posts = Repo.all(Post)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:content, source)

# Load comments for all posts with same limit
loader =
  posts
  |> Enum.reduce(loader, fn post, acc ->
    Dataloader.load(acc, :content, {Comment, %{limit: 10}}, post_id: post.id)
  end)
  |> Dataloader.run()

# Get limited comments for each post
Enum.each(posts, fn post ->
  comments = Dataloader.get(loader, :content, {Comment, %{limit: 10}}, post_id: post.id)
  IO.puts("Post '#{post.title}': #{length(comments)} comments (max 10)")
end)
```

**Note:** Each post gets its own query because each needs a separate LIMIT.
For truly efficient batching with per-parent limits, you can use SQL window functions
in a custom `run_batch/5` function.

### Combining LIMIT with Other Parameters

You can combine limit/offset with other query parameters for filtered pagination:

```elixir
defmodule MyApp.Content do
  def query(Comment, params) do
    Comment
    |> apply_filters(params)
    |> apply_limit(params)
    |> apply_offset(params)
    |> order_by([c], desc: c.inserted_at)
  end

  def query(queryable, _), do: queryable

  defp apply_filters(query, %{author_name: author}) do
    where(query, [c], c.author_name == ^author)
  end
  defp apply_filters(query, _), do: query

  defp apply_limit(query, %{limit: limit}) do
    limit(query, ^limit)
  end
  defp apply_limit(query, _), do: query

  defp apply_offset(query, %{offset: offset}) do
    offset(query, ^offset)
  end
  defp apply_offset(query, _), do: query
end

# Load Alice's comments on a post, page 2 (10 per page)
post = Repo.get(Post, 123)

loader
|> Dataloader.load(:content,
    {Comment, %{author_name: "Alice", offset: 10, limit: 10}},
    post_id: post.id)
|> Dataloader.run()

comments = Dataloader.get(loader, :content,
  {Comment, %{author_name: "Alice", offset: 10, limit: 10}},
  post_id: post.id)
# => Alice's comments 11-20 on this post
```

### Other Pagination Approaches

While `limit` and `offset` cover most use cases, there are alternatives:

**Cursor-Based Pagination:** Instead of using offset, you can use cursors (based on ID or timestamp) with `limit`. This is faster for deep pagination (offset 10000 is slow, cursors stay fast) and better for infinite scroll. Commonly used in GraphQL Relay APIs.

**Window Functions:** For per-parent limits with efficient batching, use SQL `ROW_NUMBER()` in a custom `run_batch/5` function.

See the Dataloader Ecto documentation for advanced pagination techniques.

---

### Important Considerations

**1. LIMIT and OFFSET are Part of the Batch Key**

This is crucial to understand:

```elixir
# These are THREE different batches (won't be combined):
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 1)
Dataloader.load(loader, :db, {Comment, %{limit: 20}}, post_id: 2)
Dataloader.load(loader, :db, {Comment, %{offset: 0, limit: 10}}, post_id: 3)

# These CAN be batched together (same limit):
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 1)
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 2)
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 3)
# All three use the same batch key: {Comment, %{limit: 10}}
```

**2. OFFSET Performance Degradation**

```elixir
# Fast: SELECT * FROM comments LIMIT 10 OFFSET 0
loader |> Dataloader.load(:db, {Comment, %{offset: 0, limit: 10}}, ...)

# Slow: SELECT * FROM comments LIMIT 10 OFFSET 10000
# Database must scan and skip 10,000 rows!
loader |> Dataloader.load(:db, {Comment, %{offset: 10000, limit: 10}}, ...)
```

For large offsets (> 1000), prefer cursor-based pagination.

**3. Per-Parent LIMIT and Batching**

When you want the same `limit` for multiple parents, each parent still gets its
own separate result set:

```elixir
# Load 10 comments for each post
posts
|> Enum.reduce(loader, fn post, acc ->
  Dataloader.load(acc, :db, {Comment, %{limit: 10}}, post_id: post.id)
end)

# Each post gets UP TO 10 comments
# Post 1: 10 comments, Post 2: 3 comments, Post 3: 10 comments, etc.
```

**Note:** For advanced cases where you need per-parent limits with efficient batching,
you can use SQL window functions (ROW_NUMBER) in a custom `run_batch/5` function.

**4. Caching Implications of LIMIT/OFFSET**

Each unique combination of limit/offset creates a separate cache entry:

```elixir
# These are THREE different cache entries:
Dataloader.load(loader, :db, {Comment, %{limit: 10, offset: 0}}, ...)   # Cache key 1
Dataloader.load(loader, :db, {Comment, %{limit: 10, offset: 10}}, ...)  # Cache key 2
Dataloader.load(loader, :db, {Comment, %{limit: 10, offset: 20}}, ...)  # Cache key 3

# Even if you load the same post_id, different limits = different cache:
Dataloader.load(loader, :db, {Comment, %{limit: 5}}, post_id: 1)   # Cache entry A
Dataloader.load(loader, :db, {Comment, %{limit: 10}}, post_id: 1)  # Cache entry B (separate!)
```

This means paginating through results creates many cache entries. This is expected
behavior, but be aware when monitoring memory usage.

**5. Getting Total Count with Paginated Results**

When paginating, you often need both the limited results AND the total count.
Use a custom `run_batch/5` to return both:

```elixir
# In your query function, LIMIT is still applied
def query(Comment, %{limit: limit}) do
  Comment |> limit(^limit) |> order_by([c], desc: c.inserted_at)
end

# In custom run_batch, fetch count separately
def run_batch(Comment, query, :comments_with_count, inputs, repo_opts) do
  # Return both comments and total_count for each input
  Enum.map(inputs, fn input ->
    %{
      comments: query |> Repo.all(repo_opts),      # Limited by query/2
      total_count: query |> Repo.aggregate(:count)  # Total without limit
    }
  end)
end
```

This is useful for showing "Showing 10 of 247 comments" type information.

### Best Practices for Pagination

✅ **DO:**
- **Always include limit/offset in the batch key tuple**: `{Comment, %{limit: 10}}`
- **Keep limit values consistent** across similar queries to enable batching
- **Use LIMIT for simple "top N" queries**: Fast and simple (e.g., "10 most recent comments")
- **Use OFFSET + LIMIT for traditional page navigation**: Pages 1, 2, 3, etc.
- **Put limit/offset logic in query/2**: Keep it clean and reusable
- **Order your results**: Always use `order_by` with LIMIT to ensure consistency

❌ **DON'T:**
- **Forget the batch key must match**: `load` and `get` must use identical params
- **Use different limits unnecessarily**: Fragments batching opportunities
- **Use very large offsets**: Offset 10000+ is slow (consider cursors for deep pagination)
- **Paginate in Elixir after loading**: Let the database handle it with LIMIT/OFFSET
- **Forget to order results**: LIMIT without ORDER BY gives unpredictable results

### Quick Reference

```elixir
# Basic LIMIT - Get first 10 comments for a post
loader
|> Dataloader.load(:db, {Comment, %{limit: 10}}, post_id: post.id)

# LIMIT + OFFSET - Page 2 (skip first 10, get next 10)
loader
|> Dataloader.load(:db, {Comment, %{offset: 10, limit: 10}}, post_id: post.id)

# LIMIT with cardinality (querying by non-PK column)
loader
|> Dataloader.load(:db, {{:many, Comment}, %{limit: 5}}, author_name: "Alice")

# LIMIT + other filters
loader
|> Dataloader.load(:db, {Comment, %{limit: 10, author_name: "Bob"}}, post_id: post.id)

# Load multiple pages at once
loader
|> Dataloader.load(:db, {Comment, %{offset: 0, limit: 10}}, post_id: post.id)   # First 10
|> Dataloader.load(:db, {Comment, %{offset: 10, limit: 10}}, post_id: post.id)  # Next 10
|> Dataloader.load(:db, {Comment, %{offset: 20, limit: 10}}, post_id: post.id)  # Next 10
```

### Common Patterns Summary

**Pattern 1: Top N items**
```elixir
# Get 10 most recent comments for a post
{Comment, %{limit: 10}}
```

**Pattern 2: Traditional pagination**
```elixir
# Page number to offset
page = 3
page_size = 10
offset = (page - 1) * page_size  # => 20

{Comment, %{offset: offset, limit: page_size}}
```

**Pattern 3: Same limit for all parents (enables batching)**
```elixir
# All posts get same limit - queries can batch!
posts
|> Enum.reduce(loader, fn post, acc ->
  Dataloader.load(acc, :db, {Comment, %{limit: 10}}, post_id: post.id)
end)
```

---

## 11. Error Handling Policies

Dataloader has three strategies for handling errors:

### 1. `:raise_on_error` (Default)

```elixir
loader = Dataloader.new()  # Default policy
|> Dataloader.add_source(:db, source)
|> Dataloader.load(:db, User, 999)  # Non-existent ID
|> Dataloader.run()

Dataloader.get(loader, :db, User, 999)
# => nil (not found, but no error)

# But if there was an exception during loading:
Dataloader.get(loader, :db, User, "explode")
# => Raises Dataloader.GetError with original exception
```

### 2. `:return_nil_on_error`

```elixir
loader = Dataloader.new(get_policy: :return_nil_on_error)
|> Dataloader.add_source(:db, source)
|> Dataloader.load(:db, User, "explode")
|> Dataloader.run()

Dataloader.get(loader, :db, User, "explode")
# => nil (logs error but returns nil instead of raising)
```

### 3. `:tuples`

```elixir
loader = Dataloader.new(get_policy: :tuples)
|> Dataloader.add_source(:db, source)
|> Dataloader.load(:db, User, 1)
|> Dataloader.load(:db, User, "explode")
|> Dataloader.run()

Dataloader.get(loader, :db, User, 1)
# => {:ok, %User{}}

Dataloader.get(loader, :db, User, "explode")
# => {:error, {%RuntimeError{}, stacktrace}}
```

### Choosing a Policy

- **`:raise_on_error`** - Use in development, fail fast
- **`:return_nil_on_error`** - Use when errors should be graceful
- **`:tuples`** - Use when you need fine-grained error handling

---

## 12. Common Patterns & Best Practices

### Pattern 1: Multiple Sources

```elixir
# Organize by context
accounts_source = Dataloader.Ecto.new(Repo, query: &Accounts.query/2)
content_source = Dataloader.Ecto.new(Repo, query: &Content.query/2)
api_source = Dataloader.KV.new(&API.fetch/2)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:accounts, accounts_source)
  |> Dataloader.add_source(:content, content_source)
  |> Dataloader.add_source(:api, api_source)

# Each source has its own scoping and rules
```

### Pattern 2: Reuse Loaders

```elixir
# Load, run, get, then load more!
loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, source)
  |> Dataloader.load(:db, User, 1)
  |> Dataloader.run()

user = Dataloader.get(loader, :db, User, 1)

# Reuse the same loader (results are cached)
loader =
  loader
  |> Dataloader.load(:db, :posts, user)
  |> Dataloader.run()

posts = Dataloader.get(loader, :db, :posts, user)
```

### Pattern 3: Nested Loading

```elixir
# Load posts, then load each post's comments
posts = Repo.all(Post)

loader =
  Dataloader.new()
  |> Dataloader.add_source(:db, source)
  |> Dataloader.load_many(:db, :comments, posts)
  |> Dataloader.run()

# Now all comments for all posts are loaded efficiently
Enum.each(posts, fn post ->
  comments = Dataloader.get(loader, :db, :comments, post)
  IO.inspect(comments)
end)
```

### Best Practices

 **DO:**
- Create one loader per request (e.g., in Phoenix controller/resolver)
- Use descriptive source names (`:accounts`, `:content`, not `:db1`, `:db2`)
- Put authorization logic in `query/2` functions
- Use `default_params` for request-scoped data (current_user, tenant_id)
- Cache loaders in process dictionary or conn assigns if needed

L **DON'T:**
- Share loaders across requests (not thread-safe)
- Put business logic in `run_batch/5` (use `query/2` instead)
- Load data you already have
- Forget to call `run/1` before `get/4`

---

## 13. Troubleshooting

### Problem: "Unable to find batch"

```elixir
# ERROR
loader = Dataloader.new() |> Dataloader.add_source(:db, source)
Dataloader.get(loader, :db, User, 1)  # ERROR!

# FIX: You forgot to load and run!
loader
|> Dataloader.load(:db, User, 1)
|> Dataloader.run()
|> Dataloader.get(:db, User, 1)
```

### Problem: "Source does not exist"

```elixir
# ERROR: Wrong source name
loader
|> Dataloader.load(:wrong_name, User, 1)  # ERROR!

# FIX: Use the correct source name
loader
|> Dataloader.add_source(:db, source)
|> Dataloader.load(:db, User, 1)
```

### Problem: Getting nil unexpectedly

```elixir
# When loading by column, did you specify cardinality?
loader
|> Dataloader.load(:db, User, email: "test@test.com")  # WRONG!
|> Dataloader.load(:db, {:one, User}, email: "test@test.com")  # CORRECT!
```

### Problem: Multiple Results Error

```elixir
# ERROR: Multiple users with role="admin", but you specified :one
loader
|> Dataloader.load(:db, {:one, User}, role: "admin")

# FIX: Use :many for non-unique columns
loader
|> Dataloader.load(:db, {:many, User}, role: "admin")
```

### Problem: Data not batching

```elixir
# This loads separately (not batched)
loader = Dataloader.new() |> Dataloader.add_source(:db, source)
loader1 = Dataloader.load(loader, :db, User, 1) |> Dataloader.run()
loader2 = Dataloader.load(loader, :db, User, 2) |> Dataloader.run()
# ^ Two separate queries!

# FIX: Load all before running
loader
|> Dataloader.load(:db, User, 1)
|> Dataloader.load(:db, User, 2)
|> Dataloader.run()  # Single query!
```

### Problem: Timeout errors

```elixir
# Increase timeout
source = Dataloader.KV.new(&slow_function/2, timeout: 60_000)

# Or for the whole loader
loader = Dataloader.new(timeout: 60_000)
```

### Debugging Tips

```elixir
# 1. Enable Ecto query logging
config :my_app, MyApp.Repo,
  log: :debug

# 2. Use telemetry to track dataloader events
:telemetry.attach_many(
  :debug,
  [
    [:dataloader, :source, :run, :start],
    [:dataloader, :source, :run, :stop]
  ],
  fn event, measurements, metadata, _ ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)

# 3. Inspect the loader struct
loader |> IO.inspect(label: "Current loader state")
```

---

## Quick Reference Card

```elixir
# CREATE
loader = Dataloader.new(get_policy: :raise_on_error)
source = Dataloader.Ecto.new(Repo, query: &query/2)
loader = Dataloader.add_source(loader, :db, source)

# LOAD
loader = Dataloader.load(loader, :db, User, 1)
loader = Dataloader.load_many(loader, :db, User, [1,2,3])
loader = Dataloader.load(loader, :db, :posts, user)
loader = Dataloader.load(loader, :db, {:one, User}, email: "test@test.com")
loader = Dataloader.load(loader, :db, {User, %{order: :asc}}, 1)

# RUN
loader = Dataloader.run(loader)

# GET
user = Dataloader.get(loader, :db, User, 1)
users = Dataloader.get_many(loader, :db, User, [1,2,3])
```

---

## Conclusion

Dataloader is a powerful tool for solving the N+1 query problem. The key is understanding
the LOAD ? RUN ? GET cycle and how batching works.

Start simple with basic Ecto queries, then gradually add:
1. Custom query functions
2. Association loading
3. Multiple sources
4. Custom run_batch functions

Happy batching!
