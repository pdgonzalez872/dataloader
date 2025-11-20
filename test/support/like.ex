defmodule Dataloader.Like do
  use Ecto.Schema

  schema "likes" do
    belongs_to(:user, Dataloader.User)
    belongs_to(:post, Dataloader.Post, where: [status: "published"])
    belongs_to(:picture, Dataloader.Picture)
    field(:status, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
