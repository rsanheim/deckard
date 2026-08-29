# Source-side seed data. Run with DECKARD_SEED=1 to get past the model
# guards that exist to prove deckard's callback/validation bypass.
raise "run seeds with DECKARD_SEED=1" unless ENV["DECKARD_SEED"]

rachael = Author.create!(name: "Rachael", email: "rachael@tyrell.example")
deckard = Author.create!(name: "Rick Deckard", email: "deckard@lapd.example")

Profile.create!(author: rachael, bio: "More human than human")
Profile.create!(author: deckard, bio: "Blade runner, retired")

nexus = Post.create!(author: rachael, title: "Nexus-6 field notes", body: "Memories are implants.")
origami = Post.create!(author: deckard, title: "Unicorn origami", body: "Left outside the door.")

# Comments cross-reference both authors so the stream exercises shared
# dependencies: one destination copy, many foreign keys.
Comment.create!(post: nexus, author: deckard, body: "Have you ever retired a human by mistake?")
Comment.create!(post: nexus, author: rachael, body: "I'm not in the business. I am the business.")
Comment.create!(post: origami, author: rachael, body: "It's too bad she won't live.")
