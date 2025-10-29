import React from "react"

import LookupLayout from "$app/components/Public/LookupLayout"

const ChargePage = () => (
  <LookupLayout
    title="Why is there a charge on my account?"
    type="charge"
  >
    <form>
      <section className="p-4! md:p-8!">
        <header>
          <h2>Who/what is Gumroad?</h2>
        </header>
        <div className="paragraphs">
          <p>We are a service that lets creators sell their stuff directly to you. We help thousands of musicians, artists, and authors sell things like music, documentaries, and eBooks.</p>
          <p>We are a venture-backed startup based in San Francisco, CA — funded by Max Levchin, a co-founder of PayPal, and Accel Partners, the lead early investor in Facebook.</p>
        </div>
      </section>
    </form>
    <form>
      <section className="p-4! md:p-8!">
        <header>
          <h2>
            <a href="/help/article/214-why-was-i-charged-by-gumroad" target="_blank" rel="noreferrer">
              Can I get a refund?
            </a>
          </h2>
        </header>
      </section>
    </form>

  </LookupLayout>
)

export default ChargePage
