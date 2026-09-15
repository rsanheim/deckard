# frozen_string_literal: true

require "bigdecimal"
require "securerandom"

# A small forum with realistic data: several authors who comment on each
# other's posts (shared dependencies), threaded replies (self-reference),
# mentions, reactions on posts and comments (polymorphic), tags, bookmarks,
# attachments with variants (UUID keys), donations, and daily view counts
# (composite key). Loaded by `rake db:seed` and by the canonical graph spec.
#
# No author has a featured post: that column forms a dependency cycle with
# posts.author_id, which deckard rejects rather than resolves.

rachael = Author.create!(
  username: "rachael", name: "Rachael", email: "rachael@tyrell.example",
  bio: "Memories. You're talking about memories.", location: "Los Angeles, CA",
  website: "https://tyrell.example/rachael", verified: true, role: :moderator,
  settings: {"theme" => "dark", "email_notifications" => false, "digest" => "weekly"},
  birthday: Date.new(2016, 1, 1), api_token: SecureRandom.uuid,
  avatar: "\x89PNG\r\n\x1A\n\x00\x00\x00\rIHDR".b,
  private_notes: "Implanted memories belong to Tyrell's niece.",
  joined_at: Time.utc(2019, 11, 1, 9, 30, 15, 250_000)
)
deckard = Author.create!(
  username: "deckard", name: "Rick Deckard", email: "deckard@lapd.example",
  bio: "Blade runner, retired. Twice.", location: "Los Angeles, CA",
  settings: {"theme" => "light", "email_notifications" => true},
  joined_at: Time.utc(2019, 11, 2, 22, 5)
)
gaff = Author.create!(
  username: "gaff", name: "Eduardo Gaff", email: "gaff@lapd.example",
  bio: "Origami enthusiast.", role: :admin, verified: true,
  settings: {"theme" => "dark"}, joined_at: Time.utc(2019, 10, 20, 8)
)

Profile.create!(author: rachael, bio: "More human than human.")
Profile.create!(author: deckard, bio: "Ex-cop. Ex-blade runner. Ex-killer.")
Profile.create!(author: gaff, bio: "It's too bad she won't live. But then again, who does?")

AuthorEmail.create!(author: rachael, address: "rachael@tyrell.example", label: "work", verified_at: Time.utc(2019, 11, 1, 10))
AuthorEmail.create!(author: rachael, address: "rachael@offworld.example", label: "personal")
AuthorEmail.create!(author: deckard, address: "deckard@lapd.example", label: "work", verified_at: Time.utc(2019, 11, 3))

general = Category.create!(name: "General", slug: "general", description: "Anything goes.")
announcements = AnnouncementCategory.create!(
  name: "Announcements", slug: "announcements",
  description: "Forum news.", moderator_notes: "Moderators only. Pin sparingly."
)

replicants = Tag.create!(name: "replicants", slug: "replicants")
memories = Tag.create!(name: "memories", slug: "memories")
lapd = Tag.create!(name: "lapd", slug: "lapd")

nexus = Post.create!(
  author: rachael, category: general, title: "Nexus-6 field notes",
  body: "Field observations on the Nexus-6 line. Memories are implants, and the implants are getting better.",
  status: "published", visibility: "public", language: "en",
  keywords: %w[nexus-6 tyrell implants], metadata: {"format" => "markdown", "reading_time" => 4},
  published_at: Time.utc(2026, 8, 20, 15, 30)
)
PostTag.create!(post: nexus, tag: replicants)
PostTag.create!(post: nexus, tag: memories)

origami = Post.create!(
  author: deckard, category: general, title: "Unicorn origami",
  body: "Left outside the door. Somebody knew I'd be there.",
  status: "published", language: "en", keywords: %w[origami unicorn],
  metadata: {"format" => "markdown", "featured" => true}, published_at: Time.utc(2026, 8, 22, 9)
)
PostTag.create!(post: origami, tag: lapd)

Post.create!(
  author: rachael, title: "Voight-Kampff, from the other side",
  body: "Draft. Do not publish. The questions are not what they seem.",
  status: "draft", visibility: "followers", sensitive: true, keywords: %w[voight-kampff],
  metadata: {"format" => "markdown"}
)

welcome = Post.create!(
  author: gaff, category: announcements, title: "Welcome to the forum",
  body: "Be kind. Retire nobody.", status: "published", language: "en",
  metadata: {"format" => "markdown", "pinned" => true}, published_at: Time.utc(2026, 8, 1, 12)
)

question = Comment.create!(post: nexus, author: deckard, body: "Have you ever retired a human by mistake?")
answer = Comment.create!(post: nexus, author: rachael, parent: question, body: "I'm not in the business. I am the business.")
followup = Comment.create!(post: nexus, author: deckard, parent: answer, body: "That's not an answer, @rachael.")
Comment.create!(post: nexus, author: gaff, body: "You've done a man's job, sir.")
Comment.create!(post: origami, author: rachael, body: "It's too bad she won't live. But then again, who does?")
Comment.create!(post: welcome, author: deckard, body: "Noted.")

Mention.create!(comment: answer, mentioned_username: "deckard")
Mention.create!(comment: followup, mentioned_username: "rachael")

Reaction.create!(author: deckard, reactable: nexus, kind: "like")
Reaction.create!(author: gaff, reactable: nexus, kind: "insightful")
Reaction.create!(author: rachael, reactable: origami, kind: "like")
Reaction.create!(author: rachael, reactable: question, kind: "like")
Reaction.create!(author: gaff, reactable: answer, kind: "laugh")

rachael.bookmarked_posts << origami
deckard.bookmarked_posts << nexus
deckard.bookmarked_posts << welcome

photo = Attachment.create!(
  author: rachael, filename: "esper-photo.png", content_type: "image/png",
  byte_size: 48_213, checksum: "5d41402abc4b2a76b9719d911017c592"
)
AttachmentVariant.create!(attachment: photo, variant: "thumbnail", byte_size: 2_048)
AttachmentVariant.create!(attachment: photo, variant: "enhanced", byte_size: 96_400)
Attachment.create!(author: deckard, filename: "unicorn.jpg", content_type: "image/jpeg", byte_size: 12_900)

Donation.create!(author: deckard, post: nexus, amount: BigDecimal("5.00"), note: "For the memories.")
Donation.create!(author: gaff, post: nexus, amount: BigDecimal("12.50"), currency: "EUR")
Donation.create!(author: rachael, amount: BigDecimal("100.00"), note: "Keep the lights on.")

PostView.create!(post: nexus, viewed_on: Date.new(2026, 9, 1), count: 42)
PostView.create!(post: nexus, viewed_on: Date.new(2026, 9, 2), count: 17)
PostView.create!(post: origami, viewed_on: Date.new(2026, 9, 1), count: 8)
